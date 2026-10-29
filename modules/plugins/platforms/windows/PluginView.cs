using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;
namespace Miucs.Plugins;

/// WPF owns interaction and status overlays; this sibling popup presents the transparent Skia swap chain.
internal sealed class PluginView : VisualizationView
{
    private readonly PluginPackage package;
    private readonly PluginHost host;
    private double lastWidth=-1,lastHeight=-1,lastDpi=-1;
    private readonly PluginInfo info;
    private HwndSource? native;
    private IntPtr surface;
    private double last;
    public override string Id=>info.Id;
    public override double BaseWidth=>info.Layout.Width;
    public override double BaseHeight=>info.Layout.Height;
    public override double LayoutMinWidth=>info.Layout.MinimumWidth;
    public override double LayoutMaxWidth=>info.Layout.MaximumWidth;
    internal PluginView(PluginHost host,string id)
    {
        this.host=host;info=host.Views[id];package=host.Package(info);
        package.Post("appearanceChanged",new{ink=host.Ink,opacity=host.Opacity});
        Loaded+=(_,_)=>{package.Replacing-=Release;package.Replacing+=Release;EnsureWindow();};Unloaded+=(_,_)=>{Release();package.Replacing-=Release;};
    }
    private void EnsureWindow()
    {
        if(native!=null||!IsLoaded)return;var parent=Window.GetWindow(this);if(parent==null)return;
        // Keep this popup unowned: owned popups are always above their owner and would cover WPF controls.
        var settings=new HwndSourceParameters("Miucs plugin surface") {Width=1,Height=1,WindowStyle=unchecked((int)0x80000000),ExtendedWindowStyle=0x00200000|0x08000000|0x00000080|0x00000020|0x00000008};
        native=new HwndSource(settings);native.AddHook(HitTest);surface=PluginNative.miucs_surface_create(package.Handle,native.Handle,Id);
        if(surface!=IntPtr.Zero&&PluginNative.miucs_surface_backend(surface)==0)System.Diagnostics.Trace.WriteLine($"Plugin {Id}: CPU fallback, 30 FPS limit");
    }
    private void Release(){if(surface!=IntPtr.Zero)PluginNative.miucs_surface_destroy(surface);surface=IntPtr.Zero;native?.Dispose();native=null;}
    public override void Activate(){if(Disposed||Active)return;base.Activate();package.ActiveId=Id;package.Post("activate",new{id=Id,width=ActualWidth,height=ActualHeight,scale=VisualTreeHelper.GetDpi(this).DpiScaleX});host.UpdateSchedule();}
    protected override void ResetInput(){if(package.ActiveId==Id){package.ActiveId=null;package.Post("deactivate");host.UpdateSchedule();}if(native!=null)ShowWindow(native.Handle,0);}
    public override void Update(AudioInput audio,KeyboardInput keyboard,double deltaTime)
    {
        if(!Active||Disposed)return;EnsureWindow();if(native==null||surface==IntPtr.Zero)return;
        double now=System.Diagnostics.Stopwatch.GetTimestamp()/(double)System.Diagnostics.Stopwatch.Frequency;
        double fps=PluginNative.miucs_surface_backend(surface)==1?60:30;if(now-last<1/fps*.85)return;last=now;
        var dpi=VisualTreeHelper.GetDpi(this);var position=PointToScreen(new Point(0,0));int w=Math.Max(1,(int)(ActualWidth*dpi.DpiScaleX)),h=Math.Max(1,(int)(ActualHeight*dpi.DpiScaleY));
        if(ActualWidth!=lastWidth||ActualHeight!=lastHeight||dpi.DpiScaleX!=lastDpi){lastWidth=ActualWidth;lastHeight=ActualHeight;lastDpi=dpi.DpiScaleX;package.Post("resize",new{id=Id,width=lastWidth,height=lastHeight,scale=lastDpi});}
        var parent=Window.GetWindow(this);if(parent==null)return;
        SetWindowPos(native.Handle,new WindowInteropHelper(parent).Handle,(int)position.X,(int)position.Y,w,h,0x0010|0x0040);
        PluginNative.miucs_surface_draw(surface,(uint)w,(uint)h,dpi.DpiScaleX);
    }
    public override void Dispose(){if(Disposed)return;base.Dispose();Release();package.Replacing-=Release;host.ReleaseUnused(package);}
    private static IntPtr HitTest(IntPtr window,int message,IntPtr wParam,IntPtr lParam,ref bool handled)
    {if(message==0x0084){handled=true;return new IntPtr(-1);}return IntPtr.Zero;}
    protected override void RenderScene(DrawingContext context){}
    [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int cx,int cy,uint flags);
    [DllImport("user32.dll")]private static extern bool ShowWindow(IntPtr window,int command);
}
