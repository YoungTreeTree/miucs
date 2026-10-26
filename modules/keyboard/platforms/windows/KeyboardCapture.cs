using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Miucs.Keyboard;

/// <summary>Read-only physical-key hook on a dedicated message thread. Never translates keys to text.</summary>
public sealed class KeyboardCapture : IDisposable
{
    private readonly KeyboardChannel channel;
    private readonly object gate = new();
    private Thread? worker;
    private uint threadId;
    private bool enabled, suspended, disposed;
    private volatile bool stopping;
    private Guid session;
    private readonly HashSet<ushort> modifiersDown = new();
    private bool capsLock;
    private Native.HookProc? callback;
    private Native.TimerProc? timer;
    private bool secureDesktop;
    public KeyboardCapture(KeyboardChannel channel) { this.channel = channel; }
    public void Start() { lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); enabled = true; StartWorker(); } }
    public void Stop() { lock (gate) { enabled = false; StopWorker(KeyboardState.Stopped); } }
    public void Suspend() { lock (gate) { suspended = true; StopWorker(KeyboardState.Suspended); } }
    public void Resume() { lock (gate) { suspended = false; if (enabled && !disposed) StartWorker(); } }
    private void StartWorker()
    {
        if (!enabled || suspended || worker != null) return;
        stopping = false;
        session = channel.BeginSession(KeyboardState.Connecting);
        worker = new Thread(Run) { IsBackground = true, Name = "Miucs physical keyboard" };
        worker.Start();
    }
    private void StopWorker(KeyboardState state)
    {
        stopping = true;
        if (threadId != 0) Native.PostThreadMessage(threadId, 0x0012, 0, 0);
        worker?.Join(); worker = null; threadId = 0;
        channel.BeginSession(state);
    }
    private void Run()
    {
        int attempt = 0;
        while (!stopping)
        {
            RunSession();
            if (stopping) break;
            // A failed hook can recover without an app restart; keyboard idleness never triggers this.
            int delay = Math.Min(30000, 1000 << Math.Min(attempt++, 5));
            for (int waited = 0; !stopping && waited < delay; waited += 50) Thread.Sleep(50);
            if (!stopping) session = channel.BeginSession(KeyboardState.Recovering);
        }
    }
    private void RunSession()
    {
        nint hook = 0; nuint timerId = 0;
        try
        {
            threadId = Native.GetCurrentThreadId();
            Native.PeekMessage(out _, 0, 0, 0, 0); // Make the thread queue before Stop posts WM_QUIT.
            if (stopping) return;
            modifiersDown.Clear(); capsLock = (Native.GetKeyState(0x14) & 1) != 0;
            secureDesktop = !IsInteractiveDesktop();
            callback = OnKey;
            hook = Native.SetWindowsHookEx(13, callback, Native.GetModuleHandle(null), 0);
            if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            channel.SetState(secureDesktop ? KeyboardState.SecureInput : KeyboardState.Running);
            timer = (_, _, _, _) =>
            {
                bool secure = !IsInteractiveDesktop();
                if (secure != secureDesktop)
                {
                    secureDesktop = secure; modifiersDown.Clear();
                    session = channel.BeginSession(secure ? KeyboardState.SecureInput : KeyboardState.Running);
                }
            };
            timerId = Native.SetTimer(0, 0, 250, timer);
            if (timerId == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            while (!stopping && Native.GetMessage(out var msg, 0, 0, 0) > 0)
            { Native.TranslateMessage(ref msg); Native.DispatchMessage(ref msg); }
        }
        catch (Exception ex) when (ex is Win32Exception or ExternalException)
        { channel.BeginSession(KeyboardState.PermissionRequired); }
        finally
        {
            if (timerId != 0) Native.KillTimer(0, timerId);
            if (hook != 0) Native.UnhookWindowsHookEx(hook);
            callback = null; timer = null; modifiersDown.Clear();
        }
    }
    private nint OnKey(int code, nint wParam, nint lParam)
    {
        // Never suppress or modify the event; all paths call the next hook.
        if (code >= 0 && !stopping && !secureDesktop)
        {
            var value = Marshal.PtrToStructure<Native.KeyData>(lParam);
            if ((value.Flags & 0x12) == 0 && value.ScanCode > 0 && value.ScanCode < 256)
            {
                bool down = wParam == 0x0100 || wParam == 0x0104;
                bool up = wParam == 0x0101 || wParam == 0x0105;
                if (down || up)
                {
                    ushort key = (ushort)(value.ScanCode | ((value.Flags & 1) != 0 ? 0x100u : 0u));
                    bool modifier = key is 0x2A or 0x36 or 0x1D or 0x11D or 0x38 or 0x138 or 0x15B or 0x15C or 0x3A;
                    bool repeatedModifier = modifier && down && modifiersDown.Contains(key);
                    if (modifier) { if (down) modifiersDown.Add(key); else modifiersDown.Remove(key); }
                    if (key == 0x3A && down && !repeatedModifier) capsLock = !capsLock;
                    if (!repeatedModifier && !(key == 0x3A && up))
                        channel.Publish(session, key, down, CurrentModifiers(), Now, modifier, key == 0x3A ? capsLock : down);
                }
            }
        }
        return Native.CallNextHookEx(0, code, wParam, lParam);
    }
    private KeyboardModifiers CurrentModifiers()
    {
        var result = capsLock ? KeyboardModifiers.CapsLock : KeyboardModifiers.None;
        if (modifiersDown.Contains(0x2A) || modifiersDown.Contains(0x36)) result |= KeyboardModifiers.Shift;
        if (modifiersDown.Contains(0x1D) || modifiersDown.Contains(0x11D)) result |= KeyboardModifiers.Control;
        if (modifiersDown.Contains(0x38) || modifiersDown.Contains(0x138)) result |= KeyboardModifiers.Option;
        if (modifiersDown.Contains(0x15B) || modifiersDown.Contains(0x15C)) result |= KeyboardModifiers.Command;
        return result;
    }
    private static bool IsInteractiveDesktop()
    {
        nint desktop = Native.OpenInputDesktop(0, false, 1);
        if (desktop == 0) return false;
        try
        {
            var name = new System.Text.StringBuilder(256);
            return Native.GetUserObjectInformation(desktop, 2, name, name.Capacity * 2, out _) && name.ToString().Equals("Default", StringComparison.OrdinalIgnoreCase);
        }
        finally { Native.CloseDesktop(desktop); }
    }
    private static double Now => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    public void Dispose() { lock (gate) { if (disposed) return; enabled = false; StopWorker(KeyboardState.Stopped); disposed = true; } }
    private static class Native
    {
        internal delegate nint HookProc(int code, nint wParam, nint lParam);
        internal delegate void TimerProc(nint hwnd, uint msg, nuint id, uint time);
        [StructLayout(LayoutKind.Sequential)] internal struct KeyData { public uint VirtualKey, ScanCode, Flags, Time; public nuint ExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] internal struct Message { public nint Hwnd; public uint Msg; public nuint WParam; public nint LParam; public uint Time; public int X, Y; public uint Private; }
        [DllImport("user32.dll", SetLastError = true)] internal static extern nint SetWindowsHookEx(int kind, HookProc proc, nint module, uint thread);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnhookWindowsHookEx(nint hook);
        [DllImport("user32.dll")] internal static extern nint CallNextHookEx(nint hook, int code, nint wp, nint lp);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? name);
        [DllImport("kernel32.dll")] internal static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] internal static extern int GetMessage(out Message msg, nint hwnd, uint min, uint max);
        [DllImport("user32.dll")] internal static extern bool PeekMessage(out Message msg, nint hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] internal static extern bool TranslateMessage(ref Message msg);
        [DllImport("user32.dll")] internal static extern nint DispatchMessage(ref Message msg);
        [DllImport("user32.dll")] internal static extern bool PostThreadMessage(uint thread, uint msg, nuint wp, nint lp);
        [DllImport("user32.dll")] internal static extern short GetKeyState(int key);
        [DllImport("user32.dll")] internal static extern nint OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
        [DllImport("user32.dll")] internal static extern bool CloseDesktop(nint desktop);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool GetUserObjectInformation(nint handle, int index, System.Text.StringBuilder value, int length, out int needed);
        [DllImport("user32.dll")] internal static extern nuint SetTimer(nint hwnd, nuint id, uint interval, TimerProc callback);
        [DllImport("user32.dll")] internal static extern bool KillTimer(nint hwnd, nuint id);
    }
}
