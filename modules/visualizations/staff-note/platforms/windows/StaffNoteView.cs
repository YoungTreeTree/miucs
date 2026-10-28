using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using Miucs.Audio;
using Miucs.Keyboard;

namespace Miucs.Visualizations;

public class StaffNoteView : VisualizationView
{
    public override string Id => "staff-note";
    public override double BaseWidth => 800;
    public override double BaseHeight => 160;
    public override double LayoutMinWidth => 80;
    public override double LayoutMaxWidth => 1600;
    public StaffNoteScene Scene { get; } = new();
    private static readonly StreamGeometry Star = CreateStar();
    private static readonly StreamGeometry Flag = Path(c => { c.BeginFigure(new Point(7,-31),false,false); c.BezierTo(new Point(27,-22),new Point(25,-12),new Point(13,-7),true,false); c.BezierTo(new Point(21,-18),new Point(15,-20),new Point(7,-23),true,false); });
    private static readonly StreamGeometry Clef = Path(c => {
        c.BeginFigure(new Point(45,102),false,false);
        c.BezierTo(new Point(54,112),new Point(64,103),new Point(58,86),true,false);
        c.BezierTo(new Point(48,60),new Point(43,38),new Point(53,34),true,false);
        c.BezierTo(new Point(68,36),new Point(58,54),new Point(47,64),true,false);
        c.BezierTo(new Point(23,85),new Point(47,103),new Point(62,88),true,false);
        c.BezierTo(new Point(73,74),new Point(48,65),new Point(45,82),true,false);
    });
    protected override void ResetInput() => Scene.Reset();
    public override void Update(AudioInput audio, KeyboardInput keyboard, double deltaTime)
    { if (!Active || Disposed) return; Scene.Update(audio, keyboard, deltaTime); InvalidateVisual(); }
    protected override void RenderScene(DrawingContext dc)
    {
        for (int i = 0; i < 5; i++) dc.DrawLine(Ink(.3,.8),new Point(24,58+i*8),new Point(778,58+i*8));
        dc.DrawGeometry(null, Ink(.7,1.7), Clef);
        // One stroked path and one spatial fade avoid seams between separately drawn edges.
        dc.PushClip(new RectangleGeometry(new Rect(80, 0, 560, 160)));
        dc.PushOpacityMask(TraceFade);
        dc.DrawGeometry(null, Ink(.52, 1.05), CreateTraceGeometry(Scene));
        dc.Pop(); dc.Pop();
        foreach(var star in Scene.Keyboard.Stars)
        {
            dc.PushTransform(new TranslateTransform(star.X,star.Y)); dc.PushTransform(new RotateTransform(star.Rotation*180/Math.PI)); dc.PushTransform(new ScaleTransform(star.Radius,star.Radius));
            dc.DrawGeometry(null,Ink(star.Opacity,.85/star.Radius),Star); dc.Pop();dc.Pop();dc.Pop();
        }
        DrawBeatRings(dc, Scene.Rings);
        dc.PushTransform(new TranslateTransform(640,Scene.Y)); dc.PushTransform(new ScaleTransform(Scene.Scale,Scene.Scale));
        // The head and sharp remain upright. Only stem and flag pivot around the head center.
        dc.DrawEllipse(Ink(Scene.Opacity).Brush,null,new Point(0,0),7,4.5);
        dc.DrawEllipse(null,new Pen(new SolidColorBrush(Color.FromArgb(90,255,255,255)),.65),new Point(0,0),7,4.5);
        dc.PushTransform(new RotateTransform(Scene.Sway*180/Math.PI));
        dc.DrawLine(Ink(Scene.Opacity,1.5),new Point(6,-1),new Point(6,-32));
        dc.DrawGeometry(null,Ink(Scene.Opacity,1.6),Flag); dc.Pop();
        dc.Pop();dc.Pop();
        if(Scene.Pitch is int note && new[]{1,3,6,8,10}.AsSpan().Contains(note%12)) Text(dc,"♯",621,Scene.Y-12,17,Scene.LabelOpacity);
        Text(dc,Scene.Pitch is int p ? StaffNoteScene.PitchName(p) : "—",659,Scene.Y-11,14,Scene.LabelOpacity);
    }
    internal static StreamGeometry CreateTraceGeometry(StaffNoteScene scene) => Path(context =>
    {
        foreach (var command in StaffTracePath.Build(scene))
        {
            var end = new Point(command.End.X, command.End.Y);
            switch (command.Operation)
            {
                case StaffTraceOperation.Move: context.BeginFigure(end, false, false); break;
                case StaffTraceOperation.Line: context.LineTo(end, true, false); break;
                case StaffTraceOperation.Curve:
                    context.BezierTo(new Point(command.Control1.X, command.Control1.Y),
                        new Point(command.Control2.X, command.Control2.Y), end, true, false);
                    break;
            }
        }
    });
    private static readonly LinearGradientBrush TraceFade = CreateTraceFade();
    private static LinearGradientBrush CreateTraceFade()
    {
        var fade = new LinearGradientBrush(Colors.Transparent, Colors.White, new Point(80, 0), new Point(640, 0))
        { MappingMode = BrushMappingMode.Absolute };
        fade.Freeze();
        return fade;
    }
    private static readonly double[] BeatTapers = { .48, .78, 1 };
    private static readonly StreamGeometry[] BeatMainArcs = CreateBeatPaths(new[] { (.05, 1.30), (1.88, 3.57), (4.15, 5.72) });
    private static readonly StreamGeometry[] BeatSatelliteArcs = CreateBeatPaths(new[] { (-.65, 1.55) });
    private static readonly LinearGradientBrush BeatFade = CreateBeatFade();
    private readonly Dictionary<double, Pen> beatHalos = new();
    internal void DrawBeatRings(DrawingContext dc, IReadOnlyList<StaffBeatRing> rings)
    {
        if (rings.Count == 0) return;
        // macOS allows ripples to cross the staff lines, fading only at the full canvas edges.
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, 800, 160)));
        dc.PushOpacityMask(BeatFade);
        for (int i = 0; i < Math.Min(rings.Count, StaffBeatRings.Limit); i++)
        {
            var ring = rings[i]; double scale = ring.Radius / 10;
            dc.PushTransform(new TranslateTransform(ring.X, ring.Y));
            dc.PushTransform(new ScaleTransform(scale, scale * .9));
            dc.PushTransform(new RotateTransform(ring.Rotation * 180 / Math.PI));
            var paths = ring.Arc == StaffBeatArc.Main ? BeatMainArcs : BeatSatelliteArcs;
            for (int band = 0; band < paths.Length; band++)
            {
                dc.PushOpacity(ring.Opacity * BeatTapers[band] * .8);
                dc.DrawGeometry(null, BeatHalo((ring.LineWidth + .85) / scale), paths[band]); dc.Pop();
                dc.PushOpacity(ring.Opacity * BeatTapers[band]);
                dc.DrawGeometry(null, Ink(1, ring.LineWidth / scale), paths[band]); dc.Pop();
            }
            dc.Pop(); dc.Pop(); dc.Pop();
        }
        dc.Pop(); dc.Pop();
    }
    private Pen BeatHalo(double width)
    {
        width = Math.Clamp(Math.Round(width * 20) / 20, .05, 12);
        if (!beatHalos.TryGetValue(width, out var pen))
        {
            var brush = new SolidColorBrush(Color.FromRgb(250, 250, 250)); brush.Freeze();
            pen = new Pen(brush, width) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
            pen.Freeze(); beatHalos.Add(width, pen);
        }
        return pen;
    }
    private static StreamGeometry[] CreateBeatPaths((double Start, double End)[] arcs)
    {
        var ranges = new[] { new[] { (0d, .07), (.93, 1d) }, new[] { (.07, .22), (.78, .93) }, new[] { (.22, .78) } };
        var paths = new StreamGeometry[3];
        for (int band = 0; band < paths.Length; band++)
        {
            int current = band;
            paths[band] = Path(context =>
            {
                foreach (var (start, end) in arcs) foreach (var (lo, hi) in ranges[current])
                    for (int step = 0; step <= 24; step++)
                    {
                        double angle = start + (end - start) * (lo + (hi - lo) * step / 24);
                        double radius = 10 * (1 + .016 * Math.Sin(angle * 3));
                        var point = new Point(Math.Cos(angle) * radius, Math.Sin(angle) * radius);
                        if (step == 0) context.BeginFigure(point, false, false); else context.LineTo(point, true, false);
                    }
            });
        }
        return paths;
    }
    private static LinearGradientBrush CreateBeatFade()
    {
        var fade = new LinearGradientBrush { MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(0, 0), EndPoint = new Point(0, 160) };
        fade.GradientStops.Add(new GradientStop(Colors.Transparent, 0));
        fade.GradientStops.Add(new GradientStop(Colors.White, .05));
        fade.GradientStops.Add(new GradientStop(Colors.White, .95));
        fade.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
        fade.Freeze(); return fade;
    }
    private static StreamGeometry CreateStar() => Path(c=> {
        for(int i=0;i<10;i++) { double angle=-Math.PI/2+i*Math.PI/5, r=i%2==0?1:.43;var p=new Point(Math.Cos(angle)*r,Math.Sin(angle)*r);if(i==0)c.BeginFigure(p,false,true);else c.LineTo(p,true,false); }
    });
}
