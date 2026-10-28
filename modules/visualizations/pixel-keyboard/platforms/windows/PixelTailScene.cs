using System;
using System.Collections.Generic;
using Miucs.Audio;
namespace Miucs.Visualizations;

public sealed class PixelTailScene
{
    public double Amplitude { get; private set; }
    public double Phase { get; private set; }
    public int BeatCount { get; private set; }
    public int OnsetCount { get; private set; }
    public int SpriteIndex
    {
        get { int level=Math.Clamp((int)Math.Round(Amplitude*4,MidpointRounding.AwayFromZero),0,4);
            return level==0?0:1+(level-1)*64+(int)(Phase/(2*Math.PI)*64)%64; }
    }
    private Guid? session;
    private long cursor;
    private double sinceBeat=100,period=.5,desiredPeriod=.5,strength;
    private double sinceOnset=100,onsetStrength;
    private double? sampleRate,audioTime;
    private int? channels;
    public void Reset()
    { Amplitude=Phase=0;BeatCount=OnsetCount=0;session=null;cursor=0;sinceBeat=sinceOnset=100;period=desiredPeriod=.5;strength=onsetStrength=0;sampleRate=audioTime=null;channels=null; }
    public void Update(AudioInput input,double seconds)
    {
        double dt=double.IsFinite(seconds)?Math.Max(0,seconds):0;
        if(session!=input.SessionId){Reset();session=input.SessionId;}
        sinceBeat+=dt;sinceOnset+=dt;BeatEvent? latest=null;OnsetEvent? latestOnset=null;bool running=false;
        if(input.State==AudioState.Running && input.Frame is {} frame && frame.SessionId==input.SessionId &&
           input.FrameAge is double age && double.IsFinite(age) && age>=0 && age<.4 && !frame.Audio.IsSilent)
        {
            running=true;
            bool changed=sampleRate!=null && (sampleRate!=frame.Audio.SampleRate || channels!=frame.Audio.ChannelCount || frame.Audio.Time<audioTime);
            if(changed){cursor=frame.Sequence;sinceBeat=sinceOnset=100;}
            sampleRate=frame.Audio.SampleRate;channels=frame.Audio.ChannelCount;audioTime=frame.Audio.Time;
            double now=frame.ReceivedAt+age;
            foreach(var beat in input.Beats)
            {
                double lag=now-beat.ReceivedAt;
                if(beat.Sequence<=cursor || beat.Sequence>frame.Sequence || !double.IsFinite(lag) || lag<0 || lag>.15 ||
                   !double.IsFinite(beat.Bpm) || beat.Bpm<50 || beat.Bpm>200 || !double.IsFinite(beat.Confidence) || beat.Confidence<.45 || beat.Confidence>1 ||
                   !double.IsFinite(beat.Strength) || beat.Strength<0 || beat.Strength>1)continue;
                if(latest==null || beat.Sequence>latest.Sequence)latest=beat;
            }
            if(latest==null && sinceBeat>Math.Max(.9,desiredPeriod*1.5) && sinceOnset>=.12)
                foreach(var onset in input.Onsets)
                {
                    double lag=now-onset.ReceivedAt;
                    if(onset.Sequence<=cursor || onset.Sequence>frame.Sequence || !double.IsFinite(lag) || lag<0 || lag>.15 ||
                       !double.IsFinite(onset.Strength) || onset.Strength<.18 || onset.Strength>1)continue;
                    if(latestOnset==null || onset.Sequence>latestOnset.Sequence)latestOnset=onset;
                }
            cursor=Math.Max(cursor,frame.Sequence);
            if(latest is {} pulse)
            {
                desiredPeriod=60/pulse.Bpm;if(BeatCount==0)period=desiredPeriod;
                BeatCount++;sinceBeat=now-pulse.ReceivedAt;strength=.88+.12*pulse.Strength;
                sinceOnset=100;
            }
            else if(latestOnset is {} attack)
            {OnsetCount++;sinceOnset=now-attack.ReceivedAt;onsetStrength=.55+.30*Math.Sqrt(attack.Strength);}
        }
        else{cursor=Math.Max(cursor,input.Frame?.Sequence??0);}
        bool beatEngaged=running && sinceBeat<=Math.Max(.9,desiredPeriod*1.5);
        bool onsetEngaged=running && !beatEngaged && sinceOnset<=.42;
        bool engaged=beatEngaged || onsetEngaged;
        double step=latest==null && latestOnset==null?dt:Math.Min(dt,.05);
        period+=(desiredPeriod-period)*(1-Math.Exp(-step/.14));
        double target=beatEngaged?strength:(onsetEngaged?onsetStrength:0);
        Amplitude+=(target-Amplitude)*(1-Math.Exp(-step/(engaged?.055:.08)));
        if(!engaged && Amplitude<.025)Amplitude=0;
        if(Amplitude>0)Phase=(Phase+Math.PI*step/period)%(2*Math.PI);
    }
}

public static class PixelTailSprite
{
    public const int FrameCount=257;
    public static (double X,double Y) Centerline(double t,double phase,double amplitude)
    {
        double rest=5*Math.Sin(Math.PI*t)-15*Math.Pow(t,3);
        double bend=Math.Max(0,(t-.12)/.88);
        double wave=amplitude*13*bend*bend*(3-2*bend)*Math.Sin(phase-2.4*t);
        return (12+66*t,48+rest+wave);
    }
    public static IReadOnlyList<(int X,int Y)> Pixels(int index)
    {
        double amplitude=index==0?0:((index-1)/64+1)/4d,phase=index==0?0:((index-1)%64)*2*Math.PI/64;
        var samples=new List<(double X,double Y,double R)>();
        for(int i=0;i<=100;i++)
        {
            double t=i/100d;var (x,y)=Centerline(t,phase,amplitude);
            double radius=7.5-2.2*t+.4*Math.Sin(Math.PI*t);
            samples.Add((x,y,radius));
            if(i is 22 or 42 or 64 or 82)samples.Add((x-1,y-radius+.5,2));
            if(i is 32 or 55 or 74)samples.Add((x-1,y+radius-.5,2));
        }
        var cells=new SortedSet<int>();
        foreach(var (cx,cy,radius) in samples)
        {
            int x0=Math.Max(0,(int)Math.Floor((cx-radius-1)/2)*2),x1=Math.Min(94,(int)Math.Ceiling((cx+radius-1)/2)*2);
            int y0=Math.Max(0,(int)Math.Floor((cy-radius-1)/2)*2),y1=Math.Min(86,(int)Math.Ceiling((cy+radius-1)/2)*2);
            for(int y=y0;y<=y1;y+=2)for(int x=x0;x<=x1;x+=2)
            {double dx=x+1-cx,dy=y+1-cy;if(dx*dx+dy*dy<=radius*radius)cells.Add(y*96+x);}
        }
        var pixels=new List<(int,int)>();foreach(int cell in cells)pixels.Add((cell%96,cell/96));
        return pixels;
    }
}
