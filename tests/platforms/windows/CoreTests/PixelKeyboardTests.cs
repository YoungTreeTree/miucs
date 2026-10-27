using System;
using System.Linq;
using Miucs.Keyboard;
using Miucs.Audio;
using Miucs.Visualizations;

internal static class PixelKeyboardTests
{
    public static void Run()
    {
        var scene=new PixelKeyboardScene();var id=Guid.NewGuid();long seq=0;int count=0;
        void Check(bool ok,string message){count++;if(!ok)throw new Exception(message);}
        KeyboardEvent Event(ushort code,KeyboardEventKind kind,double time,bool? down=null) => new(++seq,time,kind,code,KeyboardModifiers.None,null,down);
        KeyboardInput Input(double time,KeyboardEvent[]? events=null,ushort[]? held=null,KeyboardState state=KeyboardState.Running,KeyboardModifiers flags=KeyboardModifiers.None,long dropped=0)
            => new(id,seq,state,time,flags,(held??Array.Empty<ushort>()).Select(k=>new HeldKey(k,0)).ToArray(),0,null,events??Array.Empty<KeyboardEvent>(),dropped);
        Check(PixelKeyboardScene.Keys.Select(k=>k.Code).Distinct().Count()==PixelKeyboardScene.Keys.Count,"Unique keyboard layout");
        Check(PixelKeyboardScene.Keys.All(k=>k.X>=0 && k.X+k.Width<=800 && k.Y+34<420),"Keys fit keyboard hardware");
        var events=new[]{Event(30,KeyboardEventKind.Pressed,1),Event(36,KeyboardEventKind.Pressed,1)};
        scene.Update(Input(1,events,new ushort[]{30,36}),.016);
        Check(scene.IsLit(30)&&scene.IsLit(36)&&scene.Left.Code==30&&scene.Right.Code==36,"Both hands and keys react simultaneously");
        scene.Update(Input(2,held:new ushort[]{30,36}),1);
        Check(scene.IsLit(30)&&scene.IsLit(36),"Held keys remain depressed");
        events=new[]{Event(30,KeyboardEventKind.Released,2),Event(36,KeyboardEventKind.Released,2)};
        scene.Update(Input(2,events),.2);
        Check(!scene.IsLit(30)&&!scene.IsLit(36),"Release clears hold");
        events=new[]{Event(57,KeyboardEventKind.Pressed,3),Event(57,KeyboardEventKind.Released,3)};
        scene.Update(Input(3,events),.01);Check(scene.Left.Code==57&&scene.IsLit(57),"Short space tap stays visible");
        events=new[]{Event(57,KeyboardEventKind.Pressed,3.3),Event(57,KeyboardEventKind.Released,3.3)};
        scene.Update(Input(3.3,events),.3);Check(scene.Right.Code==57,"Space alternates paws");
        events=new[]{Event(42,KeyboardEventKind.ModifiersChanged,4,true),Event(54,KeyboardEventKind.ModifiersChanged,4,true)};
        scene.Update(Input(4,events,flags:KeyboardModifiers.Shift),.3);
        scene.Update(Input(4.3,new[]{Event(42,KeyboardEventKind.ModifiersChanged,4.3,false)},flags:KeyboardModifiers.Shift),.3);
        Check(!scene.IsLit(42)&&scene.IsLit(54),"Modifier sides release independently");
        scene.Update(Input(5,state:KeyboardState.SecureInput),.1);Check(!scene.IsLit(54),"Secure input clears keys");
        scene.Update(Input(5.1,held:new ushort[]{30}),.1);Check(!scene.IsLit(30),"Restore ignores pre-existing hold");
        scene.Update(Input(6,new[]{Event(30,KeyboardEventKind.Pressed,6)},new ushort[]{30}),.1);
        scene.Update(Input(6.1,held:new ushort[]{30},dropped:2),.1);Check(!scene.IsLit(30),"Dropped release cannot stick a key");
        id=Guid.NewGuid();seq=0;
        scene.Update(Input(9,new[]{Event(30,KeyboardEventKind.Pressed,1)},new ushort[]{30}),2);
        Check(!scene.IsLit(30),"Long-frame stale presses never replay");
        scene.Update(Input(10,new[]{Event(30,KeyboardEventKind.Repeated,10)},new ushort[]{30}),.1);
        Check(!scene.IsLit(30),"OS repeat cannot create a new press");
        scene.Reset();Check(scene.Left.Code==33&&scene.Right.Code==36,"Hide restores resting pose");
        Check(PixelPawSprite.Rows.Length==32&&PixelPawSprite.Rows.All(r=>r.Length==22),"Paw bitmap dimensions");
        var tail=new PixelTailScene();var audioID=Guid.NewGuid();
        AudioInput Sound(long sequence,double time,bool beat=false,double bpm=120,double confidence=.9,double lag=0,bool silent=false)
        {
            var sound=new AudioFeatures{Time=time,SampleRate=48000,ChannelCount=2,IsSilent=silent};
            return new(audioID,AudioState.Running,new(audioID,sequence,time,sound,null),0,Array.Empty<OnsetEvent>(),
                beat?new[]{new BeatEvent(sequence,time,time-lag,1,bpm,confidence)}:Array.Empty<BeatEvent>(),0);
        }
        tail.Update(Sound(1,0,true),0);tail.Update(Sound(2,.4),.4);double phaseBeforeBeat=tail.Phase;
        tail.Update(Sound(3,.5,true),.1);tail.Update(Sound(4,.9),.4);
        Check(phaseBeforeBeat>0 && tail.Phase>phaseBeforeBeat && tail.BeatCount==2 && tail.Amplitude>.9,"Beats preserve continuous tail motion");
        tail.Update(Sound(4,.9,true),0);tail.Update(Sound(5,1,true,confidence:.1),.1);tail.Update(Sound(6,1.1,true,lag:1),.1);
        Check(tail.BeatCount==2,"No repeated, unreliable or stale tail beats");
        tail.Update(Sound(7,5),4);Check(tail.Amplitude==0,"Tail settles after long frame without backlog");
        tail.Update(Sound(8,5.1,true),0);tail.Update(Sound(9,5.2),.1);tail.Update(Sound(10,5.5,silent:true),.3);
        Check(tail.Amplitude==0,"Silence returns tail to rest");
        audioID=Guid.NewGuid();tail.Update(Sound(1,6,true,lag:1),1);Check(tail.Amplitude==0 && tail.BeatCount==0,"Reconnect ignores stale beats");
        var fast=new PixelTailScene();var slow=new PixelTailScene();
        fast.Update(Sound(1,0,true,bpm:180),0);slow.Update(Sound(1,0,true,bpm:60),0);
        fast.Update(Sound(2,.2),.2);slow.Update(Sound(2,.2),.2);Check(fast.Phase>slow.Phase+.4,"Tail follows BPM");
        Check(Enumerable.Range(0,PixelTailSprite.FrameCount).All(i=>PixelTailSprite.Pixels(i).All(p=>p.X>=2 && p.X<=92 && p.Y>=2 && p.Y<=84) && PixelTailSprite.Pixels(i).Contains((12,48))),"Tail sprite stays in bounds with fixed root");
        var rest=PixelTailSprite.Pixels(0);
        Check(rest.Max(p=>p.X)-rest.Min(p=>p.X)>60 && rest.Max(p=>p.Y)-rest.Min(p=>p.Y)<36,"Resting tail is horizontal");
        double middleA=PixelTailSprite.Centerline(.5,1.2,1).Y-PixelTailSprite.Centerline(.5,1.2,0).Y;
        double tipA=PixelTailSprite.Centerline(1,1.2,1).Y-PixelTailSprite.Centerline(1,1.2,0).Y;
        double middleB=PixelTailSprite.Centerline(.5,2.4,1).Y-PixelTailSprite.Centerline(.5,2.4,0).Y;
        double tipB=PixelTailSprite.Centerline(1,2.4,1).Y-PixelTailSprite.Centerline(1,2.4,0).Y;
        Check(Math.Abs(middleA)<.01 && Math.Abs(tipA)>8 && Math.Abs(middleB)>3 && Math.Abs(tipB)<.01,"Bend propagates toward tip instead of rigid rotation");
        Console.WriteLine($"PASS: {count} pixel keyboard assertions");
    }
}
