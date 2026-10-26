using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Miucs.Windows;

/// <summary>A tiny owned window is the only interactive surface when the canvas is locked.</summary>
internal sealed class HoverLockControl : IDisposable
{
    private readonly Window owner;
    private readonly Window control;
    private readonly Button button;
    private readonly LockGlyph glyph = new() { Width = 34, Height = 34 };
    private readonly HoverLockState dwell = new();
    private readonly DispatcherTimer timer;
    private readonly Func<bool> available;
    private bool disposed;
    private const double Size = 34;

    public HoverLockControl(Window owner, Func<bool> available, Action toggle, bool pollPointer = true)
    {
        this.owner = owner; this.available = available;
        button = new Button
        {
            Content = glyph, Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), Cursor = Cursors.Hand, Focusable = false,
            Template = CreateTemplate()
        };
        button.Click += (_, _) => toggle();
        control = new Window
        {
            Title = "Miucs · 锁定", WindowStyle = WindowStyle.None, AllowsTransparency = true,
            Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            ShowActivated = false, Topmost = true, Width = Size, Height = Size, Content = button,
            Owner = owner
        };
        new WindowInteropHelper(control).EnsureHandle();
        NativeWindow.SetInteractive(control, true);
        owner.LocationChanged += Reposition;
        owner.SizeChanged += Reposition;
        owner.DpiChanged += Reposition;
        timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        timer.Tick += Tick;
        SetLocked(true);
        if (pollPointer) timer.Start();
    }

    private static ControlTemplate CreateTemplate()
    {
        var template = new ControlTemplate(typeof(Button));
        var content = new FrameworkElementFactory(typeof(ContentPresenter));
        content.SetValue(ContentPresenter.HorizontalAlignmentProperty, HorizontalAlignment.Stretch);
        content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Stretch);
        template.VisualTree = content;
        return template;
    }

    public void SetLocked(bool locked)
    {
        glyph.Locked = locked; glyph.InvalidateVisual();
        string label = locked ? "解锁：移动与缩放" : "锁定：恢复鼠标穿透";
        button.ToolTip = label;
        AutomationProperties.SetName(button, label);
    }

    public void Reset()
    {
        dwell.Reset();
        control.Hide();
    }

    private void Tick(object? sender, EventArgs e)
    {
        if (disposed) return;
        bool inside = false;
        if (owner.IsVisible && available() && NativeWindow.TryGetCursorPosition(out var point))
        {
            var local = owner.PointFromScreen(point);
            inside = local.X >= 0 && local.Y >= 0 && local.X < owner.ActualWidth && local.Y < owner.ActualHeight;
        }
        Sample(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency, inside);
    }

    // Shared production/test entry: synthetic tests do not read or move the physical pointer.
    internal void Sample(double now, bool inside)
    {
        if (disposed) return;
        bool show = dwell.Update(now, inside, owner.IsVisible && available());
        if (!show) { if (control.IsVisible) control.Hide(); return; }
        Position();
        if (!control.IsVisible) { control.Show(); Position(); }
    }

    internal Window TargetWindow => control;
    internal void ClickForVerification() => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private void Reposition(object? sender, EventArgs e) { if (control.IsVisible) Position(); }
    private void Position()
    {
        // PointToScreen is in physical pixels, including negative-origin / mixed-DPI monitors.
        var origin = owner.PointToScreen(new Point(Math.Max(0, (owner.ActualWidth - Size) / 2), Math.Max(4, owner.ActualHeight * .28 - Size / 2)));
        var dpi = VisualTreeHelper.GetDpi(owner);
        NativeWindow.PositionControl(control, origin, Size * dpi.DpiScaleX, Size * dpi.DpiScaleY);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true; timer.Stop(); timer.Tick -= Tick;
        owner.LocationChanged -= Reposition; owner.SizeChanged -= Reposition; owner.DpiChanged -= Reposition;
        control.Close();
    }
}

/// <summary>Two slightly irregular pencil strokes, no font or external bitmap dependency.</summary>
internal sealed class LockGlyph : FrameworkElement
{
    public bool Locked { get; set; } = true;
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(235, 251, 249, 243)), null, new Rect(1, 1, ActualWidth - 2, ActualHeight - 2), 9, 9);
        dc.PushTransform(new ScaleTransform(ActualWidth / 36, ActualHeight / 36));
        var pen = new Pen(new SolidColorBrush(Color.FromRgb(68, 66, 61)), 1.6) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        dc.DrawGeometry(null, pen, Geometry.Parse("M 10,16 L 25,15.5 26,28 10.5,28.5 Z"));
        dc.DrawGeometry(null, pen, Geometry.Parse(Locked ? "M 13,16 L 13,11 C 12.7,3.5 23,3.7 23,11 L 23,15.5" : "M 13,16 L 13,10 C 13,3.7 23,3.5 23.8,10"));
        dc.DrawGeometry(null, new Pen(new SolidColorBrush(Color.FromArgb(70, 68, 66, 61)), .7), Geometry.Parse("M 9,17 L 9.8,29 25,29 M 11,14.8 L 24,15"));
        dc.DrawEllipse(pen.Brush, null, new Point(18, 21), 1.3, 1.3);
        dc.DrawLine(pen, new Point(18, 21), new Point(18, 24));
        dc.Pop();
    }
}
