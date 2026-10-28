using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Miucs.Audio;
using Miucs.Keyboard;
namespace Miucs.Visualizations;

/// <summary>Pixel keyboard with a portrait, blank center and beat-driven black tail.</summary>
public sealed class PixelKeyboardView : VisualizationView
{
    public override string Id => "pixel-keyboard";
    public override double BaseWidth => 800;
    public override double BaseHeight => 460;
    public override double LayoutMinWidth => 80;
    public override double LayoutMaxWidth => 1600;
    public PixelKeyboardScene Keyboard { get; } = new();
    public PixelTailScene Tail { get; } = new();
    public PixelHeadScene Head { get; }
    private readonly bool ownsHead;
    private static readonly DrawingGroup[] TailFrames = BuildTailFrames();
    private static DrawingGroup[] BuildTailFrames()
    {
        var frames=new DrawingGroup[PixelTailSprite.FrameCount];
        for(int i=0;i<frames.Length;i++)
        {
            var frame=new DrawingGroup();
            using(var dc=frame.Open())foreach(var (x,y) in PixelTailSprite.Pixels(i))dc.DrawRectangle(Brushes.Black,null,new Rect(652+x,40+y,2,2));
            frame.Freeze();frames[i]=frame;
        }
        return frames;
    }
    private static readonly Brush Outline = Brush(0x393044), Dark = Brush(0x62576F), Side = Brush(0x9A8FA8), Paper = Brush(0xFBF7EF);
    private static readonly BitmapSource CatPortrait = LoadPortrait();
    private static BitmapSource LoadPortrait()
    {
        using var stream = typeof(PixelKeyboardView).Assembly.GetManifestResourceStream("Miucs.PixelCatHead.png")
            ?? throw new InvalidOperationException("Missing bundled pixel cat portrait");
        var image = BitmapFrame.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        image.Freeze(); return image;
    }
    private readonly DrawingGroup hardware;
    private readonly Dictionary<ushort, DrawingGroup> activeKeys = new();
    private readonly DrawingGroup paw;
    public PixelKeyboardView(PixelHeadScene? sharedHead = null)
    {
        Head = sharedHead ?? new PixelHeadScene(); ownsHead = sharedHead == null;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);
        hardware = new DrawingGroup(); using (var dc = hardware.Open()) DrawHardware(dc); hardware.Freeze();
        foreach (var key in PixelKeyboardScene.Keys)
        {
            var group = new DrawingGroup(); using (var dc = group.Open()) DrawKey(dc,key,true);
            group.Freeze(); activeKeys.Add(key.Code,group);
        }
        paw = new DrawingGroup();
        var palette = new[] { Brushes.Transparent, Brush(0x272330), Brush(0xFFF9EE), Brush(0xDCD6D9), Brush(0x30303D), Brush(0x484657) };
        using (var dc = paw.Open())
            for (int y=0;y<PixelPawSprite.Rows.Length;y++)
                for(int x=0;x<PixelPawSprite.Rows[y].Length;x++)
                { int n=PixelPawSprite.Rows[y][x]-'0'; if(n>0) dc.DrawRectangle(palette[n],null,new Rect(x*2+2,y*2+2,2,2)); }
        paw.Freeze();
    }
    protected override void ResetInput() { Tail.Reset(); if (ownsHead) Head.Reset(); Keyboard.Reset(); }
    public override void Update(AudioInput audio, KeyboardInput keyboard, double dt)
    {
        if (!Active || Disposed) return;
        Keyboard.Update(keyboard,dt); if (ownsHead) Head.Update(keyboard,dt); Tail.Update(audio,dt); InvalidateVisual();
    }
    protected override void RenderScene(DrawingContext dc)
    {
        dc.DrawDrawing(hardware);
        foreach(var key in PixelKeyboardScene.Keys) if(Keyboard.IsLit(key.Code)) dc.DrawDrawing(activeKeys[key.Code]);
        dc.PushTransform(new RotateTransform(Head.Angle * 180 / Math.PI,76,54+64*.88));
        dc.DrawImage(CatPortrait,new Rect(44,54,64,64)); dc.Pop();
        dc.DrawDrawing(TailFrames[Tail.SpriteIndex]);
        foreach(var (state,angle) in new[]{(Keyboard.Left,-7d),(Keyboard.Right,7d)})
        {
            dc.PushTransform(new TranslateTransform(state.X,state.Y-(1-state.Down)*8));
            dc.PushTransform(new RotateTransform(angle)); dc.PushTransform(new ScaleTransform(1,1-state.Down*.06));
            dc.PushTransform(new TranslateTransform(-24,0)); dc.DrawDrawing(paw);
            dc.Pop();dc.Pop();dc.Pop();dc.Pop();
        }
        if(Keyboard.State != KeyboardState.Running)
            Text(dc,Keyboard.State == KeyboardState.SecureInput ? "安全输入中 · 猫爪暂停" : "从托盘开启键盘监听，试试敲几个键",230,442,11);
    }
    private static Brush Brush(uint hex)
    { var b=new SolidColorBrush(Color.FromRgb((byte)(hex>>16),(byte)(hex>>8),(byte)hex)); b.Freeze(); return b; }
    private static void Polygon(DrawingContext dc, Brush brush, params Point[] points)
    {
        var path=Path(c=> { c.BeginFigure(points[0],true,true); for(int i=1;i<points.Length;i++)c.LineTo(points[i],true,false); });
        dc.DrawGeometry(brush,null,path);
    }
    private static void Box(DrawingContext dc,double x,double y,double w,double h,Brush b,double s=4) => Polygon(dc,b,
        new(x+s,y),new(x+w-s,y),new(x+w-s,y+s),new(x+w,y+s),new(x+w,y+h-s),new(x+w-s,y+h-s),
        new(x+w-s,y+h),new(x+s,y+h),new(x+s,y+h-s),new(x,y+h-s),new(x,y+s),new(x+s,y+s));
    private static void DrawHardware(DrawingContext dc)
    {
        foreach(double x in new[]{100d,660}) {Box(dc,x,164,40,28,Outline);Box(dc,x+5,166,30,22,Side,2);}
        Box(dc,24,0,752,172,Outline,8);Box(dc,28,4,744,164,Side,6);Box(dc,34,10,732,152,Dark);
        dc.DrawRectangle(Paper,null,new Rect(40,14,720,144));
        Polygon(dc,Outline,new(28,184),new(772,184),new(800,402),new(790,418),new(10,418),new(0,402));
        Polygon(dc,Dark,new(32,188),new(768,188),new(792,400),new(784,412),new(16,412),new(8,400));
        Polygon(dc,Side,new(34,188),new(766,188),new(786,398),new(14,398));
        dc.DrawRectangle(Brush(0xBFB5CA),null,new Rect(38,188,724,3));
        foreach(var key in PixelKeyboardScene.Keys) DrawKey(dc,key,false);
    }
    private static void DrawKey(DrawingContext dc,PixelKeyboardScene.Key key,bool active)
    {
        double x=key.X,y=key.Y,w=key.Width,offset=active?5:1;
        Box(dc,x,y,w,34,Outline,3); Box(dc,x+2,y+2,w-4,30,active?Brush(0xB85863):Brush(0xA49AAF),2);
        Box(dc,x+3,y+offset,w-6,26,active?Brush(0xEF958C):(key.Label.Length>1?Brush(0xDBD3E4):Paper),2);
        var text=new FormattedText(key.Label,CultureInfo.InvariantCulture,FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Consolas"),FontStyles.Normal,FontWeights.SemiBold,FontStretches.Normal),
            key.Label.Length>3?10:12,Outline,1);
        dc.DrawText(text,new Point(x+(w-text.Width)/2,y+offset+4));
    }
}
