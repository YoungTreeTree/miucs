using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace Miucs.Windows;

internal static class NativeWindow
{
    private const int ExtendedStyle = -20;
    private const long ToolWindow = 0x80, Transparent = 0x20, NoActivate = 0x08000000;
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }

    [StructLayout(LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out CursorPoint point);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
    [DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr dc, int index);
    [DllImport("dcomp.dll")] private static extern uint DCompositionWaitForCompositorClock(uint count, IntPtr[]? handles, uint timeout);
    [StructLayout(LayoutKind.Sequential)] private struct Margins { public int Left, Right, Top, Bottom; }

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

    public static void SetInteractive(Window window, bool interactive)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        long style = GetWindowLongPtr(hwnd, ExtendedStyle).ToInt64() | ToolWindow | NoActivate;
        style = interactive ? style & ~Transparent : style | Transparent;
        SetWindowLongPtr(hwnd, ExtendedStyle, new IntPtr(style));
        SetWindowPos(hwnd, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0020);
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
