using System;
using System.Linq;
using System.Text;
using Miucs.Keyboard;
using Miucs.Plugins;

internal static class PluginInputTests
{
    internal static void Run()
    {
        if(PhysicalKeys.Name(0x1e)!="a" || PhysicalKeys.Name(0x11d)!="rightControl" || PhysicalKeys.Name(0xffff)!=null)
            throw new Exception("Physical keyboard mapping");
        var input=new KeyboardInput(Guid.Parse("00000000-0000-0000-0000-000000000002"),3,KeyboardState.Running,5,
            KeyboardModifiers.Control,new[]{new HeldKey(0x1e,.2)},2,.1,
            new[]{new KeyboardEvent(3,4.9,KeyboardEventKind.Pressed,0x1e,KeyboardModifiers.Control)},0);
        var bytes=PluginMessagePack.Encode(input);var text=Encoding.UTF8.GetString(bytes);
        if(!text.Contains("sessionID")||!text.Contains("running")||!text.Contains("pressed")||text.Contains("keyCode")||text.Contains("KeyCode"))
            throw new Exception("Plugin boundary leaks platform key codes or changes contract spelling");
        if(bytes[0]!=0xdf || !bytes.Contains((byte)0xcb))throw new Exception("Expected binary map and floating timestamps");
        Console.WriteLine("PASS plugin input: physical identities, enum/session spelling, binary timestamps, no native key code field");
    }
}
