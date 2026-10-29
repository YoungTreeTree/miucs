using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using Miucs.Audio;
using Miucs.Keyboard;

namespace Miucs.Visualizations;

/// <summary>A single shell-owned session. It has no capture, timer, preference or window dependencies.</summary>
public abstract class VisualizationView : FrameworkElement, IDisposable
{
    public abstract string Id { get; }
    public abstract double BaseWidth { get; }
    public abstract double BaseHeight { get; }
    public abstract double LayoutMinWidth { get; }
    public abstract double LayoutMaxWidth { get; }
    protected bool Active { get; private set; }
    protected bool Disposed { get; private set; }
    private Color color = Color.FromRgb(0x3D, 0x3D, 0x3D);
    private readonly Dictionary<(int, double), Pen> pens = new();
    private readonly Dictionary<(string, double, int), FormattedText> texts = new();
    protected VisualizationView() { IsHitTestVisible = false; ClipToBounds = true; Focusable = false; }
    public void ApplyAppearance(Color ink)
    {
        if (Disposed) return;
        color = ink; pens.Clear(); texts.Clear(); InvalidateVisual();
    }
    public virtual void Activate() { if (Disposed || Active) return; Active = true; ResetInput(); InvalidateVisual(); }
    public virtual void Deactivate() { if (!Active) return; Active = false; ResetInput(); }
    protected abstract void ResetInput();
    public abstract void Update(AudioInput audio, KeyboardInput keyboard, double deltaTime);
    public virtual void Dispose() { if (Disposed) return; Deactivate(); Disposed = true; pens.Clear(); texts.Clear(); }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        if (Disposed || ActualWidth <= 0 || ActualHeight <= 0) return;
        double scale = Math.Min(ActualWidth / BaseWidth, ActualHeight / BaseHeight);
        dc.PushTransform(new ScaleTransform(scale, scale));
        RenderScene(dc); dc.Pop();
    }
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi); texts.Clear(); InvalidateVisual();
    }
    protected abstract void RenderScene(DrawingContext dc);
    protected Pen Ink(double opacity = 1, double width = 1)
    {
        int level = Math.Clamp((int)Math.Round(opacity * 32), 0, 32);
        // Animated stroke widths must not create an unbounded per-frame cache.
        width = Math.Clamp(Math.Round(width * 20) / 20, .05, 6);
        if (!pens.TryGetValue((level, width), out var pen))
        {
            var brush = new SolidColorBrush(Color.FromArgb((byte)(255 * level / 32), color.R, color.G, color.B)); brush.Freeze();
            pen = new Pen(brush, width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round }; pen.Freeze();
            pens.Add((level, width), pen);
        }
        return pen;
    }
    protected void Text(DrawingContext dc, string value, double x, double y, double size, double opacity = .8)
    {
        int level = Math.Clamp((int)Math.Round(opacity * 32), 0, 32);
        var key = (value, size, level);
        if (!texts.TryGetValue(key, out var text))
        {
            // Bound label/score caching over long-running sessions.
            if (texts.Count > 128) texts.Clear();
            text = new FormattedText(value, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe Print"), size, Ink(level / 32.0).Brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            texts[key] = text;
        }
        dc.DrawText(text, new Point(x, y));
    }
    protected static StreamGeometry Path(Action<StreamGeometryContext> draw)
    {
        var geometry = new StreamGeometry(); using (var context = geometry.Open()) draw(context); geometry.Freeze(); return geometry;
    }
}
