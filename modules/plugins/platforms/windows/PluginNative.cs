using System;
using System.Runtime.InteropServices;
using System.Text;
namespace Miucs.Plugins;
internal static class PluginNative
{
    private const string Library="miucs_plugins";
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern IntPtr miucs_plugin_open([MarshalAs(UnmanagedType.LPUTF8Str)]string worker,[MarshalAs(UnmanagedType.LPUTF8Str)]string directory);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern void miucs_plugin_close(IntPtr handle);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern int miucs_plugin_post(IntPtr handle,byte[] data,nuint length);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern int miucs_plugin_ready(IntPtr handle);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern nuint miucs_plugin_error(IntPtr handle,byte[] data,nuint length);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern IntPtr miucs_surface_create(IntPtr plugin,IntPtr window,[MarshalAs(UnmanagedType.LPUTF8Str)]string output);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern int miucs_surface_draw(IntPtr surface,uint width,uint height,double scale);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern int miucs_surface_pixels(IntPtr surface,uint width,uint height,byte[] pixels,nuint length);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern int miucs_surface_backend(IntPtr surface);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern void miucs_surface_destroy(IntPtr surface);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern nuint miucs_plugin_catalog([MarshalAs(UnmanagedType.LPUTF8Str)]string builtin,[MarshalAs(UnmanagedType.LPUTF8Str)]string user,byte[]? data,nuint length);
    [DllImport(Library,CallingConvention=CallingConvention.Cdecl)]internal static extern ulong miucs_plugin_completed(IntPtr handle);
    internal static string Error(IntPtr h){var bytes=new byte[2048];miucs_plugin_error(h,bytes,(nuint)bytes.Length);int end=Array.IndexOf(bytes,(byte)0);return Encoding.UTF8.GetString(bytes,0,end<0?bytes.Length:end);}
}
