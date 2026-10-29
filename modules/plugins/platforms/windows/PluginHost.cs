using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;
using Miucs.Audio;
using Miucs.Keyboard;
namespace Miucs.Plugins;
internal sealed record PluginLayout(double Width,double Height,double MinimumWidth,double MaximumWidth);
internal sealed record PluginInfo(string Id,string Name,string Directory,PluginLayout Layout);
internal sealed class PluginPackage : IDisposable
{
    internal readonly PluginInfo Info;
    internal IntPtr Handle;
    internal string? ActiveId;
    internal event Action? Replacing;
    internal bool IsReloading => candidate!=IntPtr.Zero;
    private IntPtr candidate;
    private long reloadStart;
    private object viewport=new Dictionary<string,object?>();
    private object appearance=new{ink="#3d3d3d",opacity=1d};
    private string fingerprint="";
    internal string ReloadError="";
    internal PluginPackage(PluginInfo info){Info=info;Handle=PluginNative.miucs_plugin_open(Path.Combine(AppContext.BaseDirectory,"miucs-plugin-worker.exe"),info.Directory);}
    internal void Post(string op,object? value=null){if((op=="activate"||op=="resize")&&value!=null)viewport=value;if(op=="appearanceChanged"&&value!=null)appearance=value;if(Handle==IntPtr.Zero)return;var bytes=PluginMessagePack.Encode(new Dictionary<string,object?>{{"op",op},{"value",value??new Dictionary<string,object?>()}});PluginNative.miucs_plugin_post(Handle,bytes,(nuint)bytes.Length);}
    internal void CheckFiles()
    {
        try {
            string value=string.Join("|",Directory.EnumerateFiles(Info.Directory,"*",new EnumerationOptions{RecurseSubdirectories=true,AttributesToSkip=FileAttributes.ReparsePoint|FileAttributes.Hidden,IgnoreInaccessible=true}).Take(4096).OrderBy(f=>f).Select(f=>{var s=new FileInfo(f);return $"{f}:{s.Length}:{s.LastWriteTimeUtc.Ticks}";}));
            if(fingerprint.Length>0&&fingerprint!=value)Reload();fingerprint=value;
        } catch(IOException e){ReloadError=e.Message;}
    }
    internal void Reload()
    {
        if(candidate!=IntPtr.Zero)return;
        candidate=PluginNative.miucs_plugin_open(Path.Combine(AppContext.BaseDirectory,"miucs-plugin-worker.exe"),Info.Directory);reloadStart=Environment.TickCount64;ReloadError="";
        if(candidate==IntPtr.Zero){ReloadError=PluginNative.Error(IntPtr.Zero);return;}
        void Send(string op,object value){var bytes=PluginMessagePack.Encode(new{op,value});PluginNative.miucs_plugin_post(candidate,bytes,(nuint)bytes.Length);}
        Send(ActiveId==null?"deactivate":"activate",viewport);Send("appearanceChanged",appearance);Send("update",new{now=0d,deltaTime=0d});
    }
    internal void PollReload()
    {
        if(candidate==IntPtr.Zero)return;string error=PluginNative.Error(candidate);
        if(error.Length>0||Environment.TickCount64-reloadStart>3000){ReloadError=error.Length>0?error:"Plugin reload timed out";PluginNative.miucs_plugin_close(candidate);candidate=IntPtr.Zero;return;}
        if(PluginNative.miucs_plugin_completed(candidate)<4)return;
        string output=Info.Id;
        var surface=PluginNative.miucs_surface_create(candidate,IntPtr.Zero,output);var pixels=new byte[16*16*4];
        bool valid=surface!=IntPtr.Zero&&PluginNative.miucs_surface_pixels(surface,16,16,pixels,(nuint)pixels.Length)==1;
        if(surface!=IntPtr.Zero)PluginNative.miucs_surface_destroy(surface);
        if(!valid){ReloadError=PluginNative.Error(IntPtr.Zero);PluginNative.miucs_plugin_close(candidate);candidate=IntPtr.Zero;return;}
        Replacing?.Invoke();var old=Handle;Handle=candidate;candidate=IntPtr.Zero;if(old!=IntPtr.Zero)PluginNative.miucs_plugin_close(old);
    }
    public void Dispose(){if(candidate!=IntPtr.Zero)PluginNative.miucs_plugin_close(candidate);candidate=IntPtr.Zero;Replacing?.Invoke();if(Handle!=IntPtr.Zero)PluginNative.miucs_plugin_close(Handle);Handle=IntPtr.Zero;}
}
internal sealed class PluginHost : IDisposable
{
    internal static bool Enabled {
        get {
            var flag = Environment.GetEnvironmentVariable("MIUCS_PLUGINS");
            var args = Environment.GetCommandLineArgs();
            if (flag == "0" || Array.IndexOf(args, "--no-plugins") >= 0) return false;
            if (flag == "1" || Array.IndexOf(args, "--plugins") >= 0) return true;
            return File.Exists(Path.Combine(AppContext.BaseDirectory, "miucs_plugins.dll"));
        }
    }
    internal readonly Dictionary<string,PluginInfo> Views=new();
    private readonly Dictionary<string,PluginPackage> packages=new();
    private readonly AudioChannel audioSource;
    private readonly KeyboardChannel keyboardSource;
    private AudioSubscription audio;
    private KeyboardSubscription keyboard;
    private readonly DispatcherTimer timer;
    private double last,lastScan;
    private bool suspended;
    internal string Error="";
    internal string Ink="#3d3d3d";
    internal double Opacity=1;
    private static double Now=>Stopwatch.GetTimestamp()/(double)Stopwatch.Frequency;
    internal PluginHost(AudioChannel a,KeyboardChannel k)
    {
        audioSource=a;keyboardSource=k;audio=a.Subscribe();keyboard=k.Subscribe();Scan();
        last=Now;timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromSeconds(1d/Miucs.Windows.NativeWindow.RefreshHz())};timer.Tick+=Tick;
    }
    internal void Scan()
    {
        string builtin=Path.Combine(AppContext.BaseDirectory,"Plugins"),user=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"Miucs","Plugins");
        nuint length=PluginNative.miucs_plugin_catalog(builtin,user,null,0);if(length>2*1024*1024)return;
        var bytes=new byte[(int)length];PluginNative.miucs_plugin_catalog(builtin,user,bytes,length);
        using var json=JsonDocument.Parse(Encoding.UTF8.GetString(bytes,0,bytes.Length-1));
        var options=new JsonSerializerOptions{PropertyNameCaseInsensitive=true};Views.Clear();
        foreach(var p in json.RootElement.GetProperty("plugins").EnumerateArray())
        {var info=p.Deserialize<PluginInfo>(options)!;Views[info.Id]=info;}
        Error=string.Join("; ",json.RootElement.GetProperty("errors").EnumerateArray().Select(e=>e.ToString()));
    }
    internal PluginPackage Package(PluginInfo info)
    {if(packages.TryGetValue(info.Id,out var p))return p;p=new PluginPackage(info);packages[info.Id]=p;return p;}
    internal void ReleaseUnused(PluginPackage package){if(package.ActiveId==null){package.Dispose();packages.Remove(package.Info.Id);}}
    internal void ReloadActive(){Error="";foreach(var p in packages.Values)p.Reload();UpdateSchedule();}
    internal void Appearance(string ink,double opacity)
    {Ink=ink;Opacity=opacity;foreach(var p in packages.Values)p.Post("appearanceChanged",new {ink,opacity});}
    internal void UpdateSchedule()
    {
        bool active=packages.Values.Any(p=>p.ActiveId!=null||p.IsReloading);
        if(suspended||!active){if(timer.IsEnabled){timer.Stop();Winmm.End();}return;}
        timer.Interval=TimeSpan.FromSeconds(1d/Miucs.Windows.NativeWindow.RefreshHz());
        if(!timer.IsEnabled){last=Now;audio.Dispose();keyboard.Dispose();audio=audioSource.Subscribe();keyboard=keyboardSource.Subscribe();Winmm.Begin();timer.Start();}
    }
    internal void Suspend(bool value)
    {
        suspended=value;UpdateSchedule();last=Now;audio.Dispose();keyboard.Dispose();audio=audioSource.Subscribe();keyboard=keyboardSource.Subscribe();
        if(value)foreach(var p in packages.Values)p.Post("update",new{now=last,deltaTime=0,keyboard=new{sessionID="suspended",sequence=0,sampledAt=last,state="suspended",events=Array.Empty<object>()}});
    }
    private void Tick(object? sender,EventArgs args)
    {
        if(suspended)return;double now=Now;if(now-last<(1d/Miucs.Windows.NativeWindow.RefreshHz())*.85)return;
        double dt=now-last;last=now;var frame=new{now,deltaTime=dt,audio=audio.Read(now),keyboard=keyboard.Read(now)};
        if(Environment.GetEnvironmentVariable("MIUCS_PLUGIN_DEV")=="1"&&now-lastScan>1){lastScan=now;foreach(var p in packages.Values)p.CheckFiles();}
        foreach(var p in packages.Values){p.PollReload();if(p.ReloadError.Length>0)Error=p.ReloadError;}
        foreach(var p in packages.Values.Where(p=>p.ActiveId!=null))
        {p.Post("update",frame);string error=PluginNative.Error(p.Handle);if(error.Length>0)Error=error;}
        UpdateSchedule();
    }
    public void Dispose(){if(timer.IsEnabled){timer.Stop();Winmm.End();}timer.Tick-=Tick;audio.Dispose();keyboard.Dispose();foreach(var p in packages.Values)p.Dispose();packages.Clear();}
}
internal static class Winmm
{
    private static int held;
    [System.Runtime.InteropServices.DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint period);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint period);
    internal static void Begin(){if(System.Threading.Interlocked.Increment(ref held)==1)timeBeginPeriod(1);}
    internal static void End(){if(System.Threading.Interlocked.Decrement(ref held)==0)timeEndPeriod(1);}
}
