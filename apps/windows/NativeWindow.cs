using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace Miucs.Windows;

internal static class NativeWindow
{
    private const int ExtendedStyle = -20;
    private const int HitTestMessage = 0x0084;
    private const int StyleChangingMessage = 0x007C;
    private const long ToolWindow = 0x80, Transparent = 0x20, NoActivate = 0x08000000, Layered = 0x00080000;
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct StyleChange { public int OldStyle, NewStyle; }

    [StructLayout(LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr dc, int index);
    [DllImport("dcomp.dll")] private static extern uint DCompositionWaitForCompositorClock(uint count, IntPtr[]? handles, uint timeout);
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }

    private sealed class PassThrough
    {
        public bool Interactive;
    }

    private static readonly ConditionalWeakTable<Window, PassThrough> PassThroughWindows = new();

    public static bool TryGetCursorPosition(out Point point)
    {
        bool found = GetCursorPos(out var native);
        point = new Point(native.X, native.Y);
        return found;
    }

    public static void PositionControl(Window window, Point origin, double width, double height)
    {
        SetWindowPos(new WindowInteropHelper(window).Handle, new IntPtr(-1), (int)Math.Round(origin.X),
            (int)Math.Round(origin.Y), (int)Math.Ceiling(width), (int)Math.Ceiling(height), 0x0010);
    }

    internal static bool IsClickThrough(Window window) =>
        (GetWindowLongPtr(new WindowInteropHelper(window).Handle, ExtendedStyle).ToInt64() & Transparent) != 0;

    internal static bool IsLayered(Window window) =>
        (GetWindowLongPtr(new WindowInteropHelper(window).Handle, ExtendedStyle).ToInt64() & Layered) != 0;

    internal static long ExStyle(IntPtr hwnd) => GetWindowLongPtr(hwnd, ExtendedStyle).ToInt64();

    internal static int HitTest(Window window, int screenX, int screenY) =>
        HitTestHandle(new WindowInteropHelper(window).Handle, screenX, screenY);

    internal static int HitTestHandle(IntPtr hwnd, int screenX, int screenY)
    {
        var packed = new IntPtr((screenY << 16) | (screenX & 0xFFFF));
        return (int)SendMessage(hwnd, HitTestMessage, IntPtr.Zero, packed).ToInt64();
    }

    public static void UseHardwareTransparency(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(hwnd, ref margins);
        if (PresentationSource.FromVisual(window) is HwndSource source)
            source.CompositionTarget.BackgroundColor = Colors.Transparent;
    }

    public static int RefreshHz(Window? window = null)
    {
        var hwnd = window == null ? IntPtr.Zero : new WindowInteropHelper(window).Handle;
        var dc = GetDC(hwnd);
        try
        {
            int hz = GetDeviceCaps(dc, 116);
            return hz >= 30 && hz <= 500 ? hz : 60;
        }
        finally { ReleaseDC(hwnd, dc); }
    }

    public static void WaitForFrame()
    {
        DCompositionWaitForCompositorClock(0, null, 34);
    }

    internal static void PassThroughSurface(HwndSource source)
    {
        var pass = new PassThrough { Interactive = false };
        source.AddHook((IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) =>
            FilterPassThrough(message, wParam, lParam, ref handled, pass));
        ApplyPassThroughStyle(source.Handle, false, false);
    }

    public static void SetInteractive(Window window, bool interactive)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        var pass = PassThroughWindows.GetValue(window, current =>
        {
            var created = new PassThrough();
            if (HwndSource.FromHwnd(new WindowInteropHelper(current).Handle) is HwndSource source)
                source.AddHook((IntPtr hookHwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) =>
                    FilterPassThrough(message, wParam, lParam, ref handled, created));
            return created;
        });
        pass.Interactive = interactive;
        ApplyPassThroughStyle(hwnd, interactive, true);
    }

    private static IntPtr FilterPassThrough(int message, IntPtr wParam, IntPtr lParam, ref bool handled, PassThrough pass)
    {
        if (message == StyleChangingMessage && wParam.ToInt64() == ExtendedStyle)
        {
            var change = Marshal.PtrToStructure<StyleChange>(lParam);
            change.NewStyle = WithPassThrough(change.NewStyle, pass.Interactive);
            Marshal.StructureToPtr(change, lParam, false);
            handled = true;
            return IntPtr.Zero;
        }
        if (message != HitTestMessage || pass.Interactive) return IntPtr.Zero;
        handled = true;
        return new IntPtr(-1);
    }

    private static int WithPassThrough(int style, bool interactive)
    {
        style |= (int)(ToolWindow | NoActivate | Layered);
        return interactive ? style & ~(int)Transparent : style | (int)Transparent;
    }

    private static void ApplyPassThroughStyle(IntPtr hwnd, bool interactive, bool topmost)
    {
        int style = WithPassThrough(unchecked((int)GetWindowLongPtr(hwnd, ExtendedStyle).ToInt64()), interactive);
        SetWindowLongPtr(hwnd, ExtendedStyle, new IntPtr(style));
        uint flags = 0x0001 | 0x0002 | 0x0010 | 0x0020;
        var after = new IntPtr(-1);
        if (!topmost) { flags |= 0x0004; after = IntPtr.Zero; }
        SetWindowPos(hwnd, after, 0, 0, 0, 0, flags);
    }

    public static WindowFrame WorkArea(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        var monitor = MonitorFromWindow(hwnd, 2);
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(monitor, ref info))
        {
            var fallback = SystemParameters.WorkArea;
            return new(fallback.X, fallback.Y, fallback.Width, fallback.Height);
        }
        var source = HwndSource.FromHwnd(hwnd);
        var transform = source?.CompositionTarget?.TransformFromDevice ?? System.Windows.Media.Matrix.Identity;
        var start = transform.Transform(new Point(info.Work.Left, info.Work.Top));
        var end = transform.Transform(new Point(info.Work.Right, info.Work.Bottom));
        return new(start.X, start.Y, end.X - start.X, end.Y - start.Y);
    }
}
