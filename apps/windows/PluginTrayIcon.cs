using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Forms=System.Windows.Forms;
namespace Miucs.Windows;
internal sealed class PluginTrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon tray;
    private Icon? current;
    private byte[]? previous;
    internal PluginTrayIcon(Forms.NotifyIcon tray){this.tray=tray;}
    internal void Present(byte[] pixels)
    {
        if(previous!=null&&pixels.AsSpan().SequenceEqual(previous))return;
        using var bitmap=new Bitmap(32,32,PixelFormat.Format32bppPArgb);
        var data=bitmap.LockBits(new Rectangle(0,0,32,32),ImageLockMode.WriteOnly,PixelFormat.Format32bppPArgb);
        try{for(int y=0;y<32;y++)Marshal.Copy(pixels,y*128,data.Scan0+y*data.Stride,128);}finally{bitmap.UnlockBits(data);}
        IntPtr handle=bitmap.GetHicon();Icon next;
        try{using var temporary=Icon.FromHandle(handle);next=(Icon)temporary.Clone();}finally{DestroyIcon(handle);}
        var old=current;current=next;tray.Icon=next;old?.Dispose();previous=pixels;
    }
    public void Dispose(){if(tray.Icon==current)tray.Icon=null;current?.Dispose();current=null;}
    [DllImport("user32.dll")]private static extern bool DestroyIcon(IntPtr icon);
}
