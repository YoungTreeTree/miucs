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
        if (!locked && owner.IsVisible && available()) Show();
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
        bool enabled = owner.IsVisible && available();
        bool hovered = dwell.Update(now, inside, enabled);
        bool show = enabled && (!glyph.Locked || hovered);
        if (!show) { if (control.IsVisible) control.Hide(); return; }
        Show();
    }

    private void Show()
    {
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
        dc.PushTransform(new ScaleTransform(ActualWidth / 34, ActualHeight / 34));
        dc.PushTransform(new ScaleTransform(.7, .7, 17, 17));
        var ink = new SolidColorBrush(Color.FromArgb(230, 69, 69, 69));
        Pen Pencil(Brush brush, double width) => new(brush, width)
            { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        var outline = Geometry.Parse("M 10.5,16 C 14,15.5 20,16.1 23.5,15.7 C 24.5,15.7 25,16.6 25,18 L 24.7,26 C 24.8,27.4 24,28.1 22.8,28 L 11,27.7 C 9.7,27.8 9.2,27.2 9.3,26 L 9.5,18 Z");
        var shackle = Geometry.Parse(Locked
            ? "M 13,15.7 L 12.8,11 C 12.5,4.1 22,4.4 21.7,10.8 L 21.8,15.8"
            : "M 13,15.7 L 12.8,11 C 12.5,2.5 24.6,2.1 24.4,9.5");
        var key = new GeometryGroup();
        key.Children.Add(new EllipseGeometry(new Rect(15.6, 19.7, 2.5, 2.6)));
        key.Children.Add(Geometry.Parse("M 16.9,22 L 16.8,24.2"));
        dc.DrawGeometry(new SolidColorBrush(Color.FromArgb(224, 250, 250, 250)), null, outline);
        foreach (var path in new Geometry[] { outline, shackle, key })
        {
            dc.DrawGeometry(null, Pencil(new SolidColorBrush(Color.FromArgb(199, 250, 250, 250)), 3.2), path);
            dc.DrawGeometry(null, Pencil(ink, 1.25), path);
        }
        dc.DrawGeometry(null, Pencil(new SolidColorBrush(Color.FromArgb(82, 69, 69, 69)), .55),
            Geometry.Parse("M 10.8,18.6 L 10.6,25.3 M 12,29 L 21.8,29.2 M 14.3,10.4 C 14.3,7.6 16.6,5.8 19.7,6.5"));
        dc.Pop();
        dc.Pop();
    }
}
