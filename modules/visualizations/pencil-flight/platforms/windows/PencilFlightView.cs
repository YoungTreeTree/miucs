using System;
using System.Windows;
using System.Windows.Media;
using Miucs.Audio;
using Miucs.Keyboard;

namespace Miucs.Visualizations;

public sealed class PencilFlightView : VisualizationView
{
    public override string Id=>"pencil-flight";
    public override double BaseWidth=>400;
    public override double BaseHeight=>260;
    public override double LayoutMinWidth=>40;
    public override double LayoutMaxWidth=>1000;
    public FlightScene Scene { get; }=new();
    private static readonly StreamGeometry Bird=Path(c=> {
        c.BeginFigure(new Point(-16,1),false,true);
        c.BezierTo(new Point(-18,-11),new Point(-4,-14),new Point(5,-8),true,false);
        c.BezierTo(new Point(11,-17),new Point(20,-10),new Point(19,-4),true,false);
        c.LineTo(new Point(26,0),true,false);c.LineTo(new Point(18,3),true,false);
        c.BezierTo(new Point(15,14),new Point(-6,14),new Point(-16,1),true,false);
    });
    private static readonly StreamGeometry Cloud=Path(c=>{
        c.BeginFigure(new Point(-22,3),false,false);c.BezierTo(new Point(-28,-4),new Point(-14,-11),new Point(-7,-7),true,false);
        c.BezierTo(new Point(-3,-22),new Point(18,-15),new Point(16,-5),true,false);
        c.BezierTo(new Point(32,-7),new Point(30,7),new Point(19,7),true,false);
        c.LineTo(new Point(-18,8),true,false);
    });
    protected override void ResetInput()=>Scene.Reset();
    public override void Update(AudioInput audio,KeyboardInput keyboard,double deltaTime)
    {if(!Active||Disposed)return;Scene.Update(audio,deltaTime);InvalidateVisual();}
    protected override void RenderScene(DrawingContext dc)
    {
        // Stable authored strokes: no render-time randomness or flickering pencil noise.
        for(int i=0;i<3;i++)
        {
            double x=(120+i*143-Scene.Elapsed*(1+Scene.Activity*2))%470;if(x<-30)x+=470;
            dc.PushTransform(new TranslateTransform(x,28+i%2*24));dc.PushTransform(new ScaleTransform(.65+i*.13,.65+i*.13));
            dc.DrawGeometry(null,Ink(.1+Scene.Brightness*.08,.8),Cloud);dc.Pop();dc.Pop();
        }
        dc.DrawLine(Ink(.16,.8),new Point(14,237),new Point(387,237));
        for(int i=0;i<16;i++)dc.DrawLine(Ink(.08,.65),new Point(10+i*25,241),new Point(18+i*25,244));
        foreach(var gate in Scene.Gates)
        {
            double opacity=Math.Clamp((gate.X-96)/210,0,1)*.7;
            if(opacity<=0)continue;
            double pulse=Scene.Bass*1.5;
            Pipe(dc,gate.X,10,Math.Max(12,gate.Top),false,opacity,pulse);
            Pipe(dc,gate.X,Math.Min(235,gate.Bottom),237,true,opacity,pulse);
        }
        foreach(var puff in Scene.Puffs)
        {
            double t=puff.Age/puff.Lifetime,s=.22+t*(.45+puff.Strength*.4);
            dc.PushTransform(new TranslateTransform(puff.X,puff.Y));dc.PushTransform(new ScaleTransform(s,s));
            dc.DrawGeometry(null,Ink((1-t)*.45,.9/s),Cloud);dc.Pop();dc.Pop();
        }
        foreach(var particle in Scene.Particles)
        {
            double opacity=Math.Clamp(1-particle.Age/particle.Lifetime,0,1)*.5;
            if(particle.Feather)
            {dc.DrawLine(Ink(opacity,.8),new Point(particle.X-4,particle.Y+2),new Point(particle.X+2,particle.Y-2));dc.DrawLine(Ink(opacity*.7,.6),new Point(particle.X-2,particle.Y+1),new Point(particle.X-3,particle.Y-3));}
            else dc.DrawEllipse(Ink(opacity).Brush,null,new Point(particle.X,particle.Y),.6+Scene.Highs,.6+Scene.Highs);
        }
        dc.PushTransform(new TranslateTransform(96,Scene.Y));dc.PushTransform(new RotateTransform(Scene.Angle*180/Math.PI));
        dc.PushTransform(new ScaleTransform(Scene.Scale,Scene.Scale));
        // Pale inner stroke improves legibility without an opaque rectangle.
        dc.DrawGeometry(null,new Pen(new SolidColorBrush(Color.FromArgb(100,255,255,255)),3),Bird);
        dc.DrawGeometry(null,Ink(.9,1.15),Bird);
        dc.DrawLine(Ink(.75,1),new Point(-16,1),new Point(-25,-5));dc.DrawLine(Ink(.6,.9),new Point(-16,3),new Point(-26,4));
        dc.DrawEllipse(Ink(.95).Brush,null,new Point(13,-6),1.25,1.25);
        double wing=-3-Scene.Flap*13*(.4+Scene.Loudness*.6);
        var wingPath=Path(c=>{c.BeginFigure(new Point(-8,1),false,false);c.QuadraticBezierTo(new Point(-10,wing),new Point(1,wing-3),true,false);c.QuadraticBezierTo(new Point(4,4),new Point(-7,6),true,false);});
        dc.DrawGeometry(null,Ink(.8,1.1),wingPath);dc.Pop();dc.Pop();dc.Pop();
        Text(dc,Scene.Note,43,Scene.Y+19,12,.65);
        Text(dc,Scene.Score.ToString(),191,17,23,.65);
    }
    private void Pipe(DrawingContext dc,double x,double top,double bottom,bool capAtTop,double opacity,double pulse)
    {
        if(bottom<=top)return;
        double cap=capAtTop?top:bottom-7;
        var pen=Ink(opacity,.9+Scene.Bass*.3);
        dc.DrawLine(pen,new Point(x-23,top),new Point(x-23,bottom));dc.DrawLine(pen,new Point(x+23,top),new Point(x+23,bottom));
        dc.DrawRoundedRectangle(null,pen,new Rect(x-28-pulse,cap,56+pulse*2,7),1,1);
        dc.DrawLine(Ink(opacity*.3,.65),new Point(x-19,top+9),new Point(x-19,bottom-9));
        for(int i=0;i<3;i++)
        {
            double y=top+12+i*9;if(y>bottom-9)break;
            dc.DrawLine(Ink(opacity*.25,.65),new Point(x+12,y+4),new Point(x+22,y));
        }
    }
}
