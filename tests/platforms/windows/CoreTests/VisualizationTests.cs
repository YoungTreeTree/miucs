using System;
using System.Collections.Generic;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;

public static class VisualizationTests
{
    private static int assertions;
    private static void Check(bool value,string message){assertions++;if(!value)throw new Exception(message);}
    private static readonly Guid AudioSession=Guid.Parse("61fcdb5b-41b8-4d14-a538-142283d2c818");
    private static readonly Guid KeySession=Guid.Parse("c55ae44f-9553-4986-a78d-981ec4b724ee");
    private static AudioInput Input(long sequence,double time,int? midi=69,bool silent=false,Guid? session=null)
    {
        var frame=new AudioFrame(session??AudioSession,sequence,time,new AudioFeatures{Time=time,SampleRate=48000,ChannelCount=2,Envelope=silent?0:.2,RmsDBFS=-14,IsSilent=silent,BandwidthHz=3000,LowEnergy=.01,MidEnergy=.02,HighEnergy=.001},
            new MelodyFrame(time,midi is int m?440*Math.Pow(2,(m-69)/12.0):null,.9,midi!=null));
        return new AudioInput(frame.SessionId,AudioState.Running,frame,0,Array.Empty<OnsetEvent>(),Array.Empty<BeatEvent>(),0);
    }
    // Construct from named properties below once keyboard contract is available.
    private static KeyboardInput EmptyKeys()=>new(KeySession,0,KeyboardState.Running,0,KeyboardModifiers.None,Array.Empty<HeldKey>(),0,null,Array.Empty<KeyboardEvent>(),0);
    public static void Run()
    {
        Check(StaffNoteScene.PitchY(71)==74,"B4 fixed staff position");
        Check(StaffNoteScene.PitchY(60)==98,"C4 true staff position");
        Check(StaffNoteScene.PitchY(61)==98,"C sharp shares C staff position");
        var staff=new StaffNoteScene();var keys=EmptyKeys();
        staff.Update(Input(1,0),keys,.016);Check(staff.Pitch==69,"initial note accepted");
        staff.Update(Input(2,.02,81),keys,.016);Check(staff.Pitch==69,"brief octave rejected");
        for(int i=3;i<12;i++)staff.Update(Input(i,(i-1)*.02,81),keys,.02);
        Check(staff.Pitch==81,"sustained octave accepted");
        int count=staff.Trace.Count;staff.Update(Input(11,.2,81),keys,.016);Check(staff.Trace.Count==count,"repeated snapshot not appended");
        staff.Update(Input(12,.24,null),keys,.016);Check(!staff.Reliable,"explicit missing pitch invalidated");
        for(int i=13;i<1000;i++)staff.Update(Input(i,i*.02,69),keys,.02);
        Check(staff.Trace.Count<=512,"trace capacity");
        staff.Update(Input(1001,20,69,true),keys,9);Check(staff.Trace.Count==0,"long scheduling gap expires full history");
        staff.Update(Input(1,0,60,session:Guid.NewGuid()),keys,.016);Check(staff.Trace.Count<=1,"generation clears trace");
        // Audio is stale independently of keyboard. A refresh must never extend its old trace.
        staff.Reset(); staff.Update(Input(1,0,60),keys,.016);
        int beforeStale = staff.Trace.Count;
        var stale = Input(2,.02,60) with { FrameAge = .5 };
        staff.Update(stale,keys,.02);
        Check(!staff.Reliable && staff.Trace.Count == beforeStale,"stale audio cannot extend trace");
        var format = Input(3,.04,60);
        format = format with { Frame = format.Frame! with { Audio = format.Frame.Audio with { SampleRate = 44100 } } };
        staff.Update(format,keys,.02);Check(staff.Trace.Count <= 1,"format change resets trace");
        var beatInput = Input(4,.06,60) with { Beats = new[]{new BeatEvent(4,.06,.06,.8,120,.9)} };
        staff.Update(beatInput,keys,.016);int ringCount=staff.Rings.Count;
        staff.Update(beatInput,keys,.016);Check(staff.Rings.Count==ringCount,"repeated beat event not replayed");
        var oldBeat = Input(5,1,60) with { Beats = new[]{new BeatEvent(5,.5,.5,.8,120,.9)} };
        staff.Update(oldBeat,keys,.016);Check(staff.Rings.Count==ringCount,"old beat event not replayed");
        staff.Reset();Check(staff.Trace.Count==0 && staff.Keyboard.Stars.Count==0,"hide/switch reset");
        var stars=new KeyboardStars();
        var press = new KeyboardEvent(1,0,KeyboardEventKind.Pressed,0x1E,KeyboardModifiers.None);
        var down = keys with { Sequence=1,Events=new[]{press},HeldKeys=new[]{new HeldKey(0x1E,0)} };
        stars.Update(down,0);Check(stars.Stars.Count==7,"ordinary key emits center and six stars");
        stars.Update(down with { Events=Array.Empty<KeyboardEvent>(),SampledAt=.31,HeldKeys=new[]{new HeldKey(0x1E,.31)} },.31);
        Check(stars.Stars.Count>6,"long hold produces independent small burst");
        stars.Update(keys with { Sequence=2,SampledAt=.32,Events=new[]{new KeyboardEvent(2,.32,KeyboardEventKind.Released,0x1E,KeyboardModifiers.None,.32)} },.01);
        stars.Update(keys with { Sequence=2,SampledAt=1 },1);Check(stars.Stars.Count==0,"release stops repeats and old particles expire");
        stars.Update(down,0);stars.Update(down with { SessionId=Guid.NewGuid(),State=KeyboardState.Suspended,Events=Array.Empty<KeyboardEvent>(),HeldKeys=Array.Empty<HeldKey>() },1);
        Check(stars.Stars.Count==0,"suspend cancels hold with full-time expiry");
        stars.Clear();stars.Update(keys with { Sequence=1,Events=new[]{press with { ReceivedAt=-1 }} },0);Check(stars.Stars.Count==0,"expired event not replayed");
        stars.Clear();
        var spam=new List<KeyboardEvent>();
        for(int i=1;i<=60;i++)spam.Add(new(i,0,KeyboardEventKind.ModifiersChanged,0x2A,KeyboardModifiers.Shift,ModifierIsPressed:true));
        stars.Update(keys with { Sequence=60,Events=spam },0);Check(stars.Stars.Count<=112,"star capacity under burst overflow");
        var silentStaff=new StaffNoteScene();silentStaff.Update(Input(1,0,null,true),down,0);
        Check(silentStaff.Keyboard.Stars.Count==7,"keyboard works during audio silence");
        silentStaff.Update(Input(1,0,null,true,Guid.NewGuid()),down with { Events=Array.Empty<KeyboardEvent>() },.02);
        Check(silentStaff.Keyboard.Stars.Count>0,"audio reconnect preserves existing stars");
        Check(KeyboardStars.Positions.ContainsKey(0x1E)&&KeyboardStars.Positions.ContainsKey(0x11D),"physical ANSI mappings include extended right modifier");
        var flight=new FlightScene();
        for(int i=1;i<=800;i++)flight.Update(Input(i,i*.02,60+i/50%2*24),.02);
        Check(flight.Gates.Count<=16&&flight.Particles.Count<=80&&flight.Puffs.Count<=6,"flight bounded collections");
        Check(flight.Scale>=.8&&flight.Scale<=1.4&&double.IsFinite(flight.Y),"finite bounded bird dynamics");
        foreach(var gate in flight.Gates)if(Math.Abs(gate.X-96)<50)Check(gate.Top<flight.Y&&gate.Bottom>flight.Y,"nearby gate yields to bird");
        flight.Update(Input(801,16.02,null),.02);Check(flight.Note=="—","flight explicit missing melody");
        Console.WriteLine($"Visualization tests: {assertions} assertions passed (portable scene only; no WPF execution).");
    }
}
