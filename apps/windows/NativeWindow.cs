using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

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
