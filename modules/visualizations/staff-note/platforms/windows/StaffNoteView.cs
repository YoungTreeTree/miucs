using System;
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
        // Trace follows notation, not volume scaling or stem rotation.
        for (int i = 1; i < Scene.Trace.Count; i++)
        {
            var a = Scene.Trace[i-1]; var b = Scene.Trace[i];
            if (a.Segment != b.Segment) continue;
            double x1 = 640 - (Scene.Elapsed - a.Time) * 70, x2 = 640 - (Scene.Elapsed - b.Time) * 70;
            double progress = b.JoinDuration <= 0 ? 1 : Math.Clamp((Scene.Elapsed - b.JoinedAt) / b.JoinDuration,0,1);
            progress = progress * progress * (3 - 2 * progress);
            var curve = Path(c => { c.BeginFigure(new Point(x1,a.Y),false,false); c.BezierTo(new Point((x1+x2)/2,a.Y),new Point((x1+x2)/2,b.Y),new Point(x2,b.Y),true,false); });
            dc.DrawGeometry(null,Ink(Math.Max(0,1-(Scene.Elapsed-a.Time)/8)*.5*progress,1.2),curve);
        }
        if (Scene.Reliable && Scene.Trace.Count > 0)
        {
            var last = Scene.Trace[^1]; double x = 640 - (Scene.Elapsed-last.Time)*70;
            var tail = Path(c => { c.BeginFigure(new Point(x,last.Y),false,false); c.BezierTo(new Point(Math.Max(x,630),last.Y),new Point(630,Scene.Y),new Point(640,Scene.Y),true,false); });
            dc.DrawGeometry(null,Ink(.5,1.2),tail);
        }
        foreach (var ring in Scene.Rings)
        {
            double t = Math.Clamp((Scene.Elapsed-ring.Born)/.89,0,1);
            for (int j = 0; j < 5; j++)
            {
                double delay = j < 2 ? j*.04 : .1+(j-2)*.055;
                double age = Scene.Elapsed-ring.Born-delay; if(age < 0) continue;
                double radius = j < 2 ? (8+24*Math.Min(1,age/.65))*(j==0?1:.73) : 3+age*12;
                double cx=ring.X, cy=ring.Y;
                if(j>=2) { double angle=j*2.2; cx+=Math.Cos(angle)*age*35; cy+=Math.Sin(angle)*age*18; }
                dc.PushClip(new RectangleGeometry(new Rect(20,54,760,40)));
                DrawArc(dc,cx,cy,radius,j*.9,.9+Math.PI*(j<2?1.15:.5),.4*Math.Pow(1-t,1.5)); dc.Pop();
            }
        }
        foreach(var star in Scene.Keyboard.Stars)
        {
            dc.PushTransform(new TranslateTransform(star.X,star.Y)); dc.PushTransform(new RotateTransform(star.Rotation*180/Math.PI)); dc.PushTransform(new ScaleTransform(star.Radius,star.Radius));
            dc.DrawGeometry(null,Ink(star.Opacity,.85/star.Radius),Star); dc.Pop();dc.Pop();dc.Pop();
        }
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
    private void DrawArc(DrawingContext dc,double x,double y,double radius,double start,double sweep,double opacity)
    {
        var geometry=Path(c=> { c.BeginFigure(new Point(x+Math.Cos(start)*radius,y+Math.Sin(start)*radius),false,false);
            c.ArcTo(new Point(x+Math.Cos(start+sweep)*radius,y+Math.Sin(start+sweep)*radius),new Size(radius,radius),0,sweep>Math.PI,SweepDirection.Clockwise,true,false); });
        dc.DrawGeometry(null,Ink(opacity,.9),geometry);
    }
    private static StreamGeometry CreateStar() => Path(c=> {
        for(int i=0;i<10;i++) { double angle=-Math.PI/2+i*Math.PI/5, r=i%2==0?1:.43;var p=new Point(Math.Cos(angle)*r,Math.Sin(angle)*r);if(i==0)c.BeginFigure(p,false,true);else c.LineTo(p,true,false); }
    });
}
