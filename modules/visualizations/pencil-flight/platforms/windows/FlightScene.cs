using System;
using System.Collections.Generic;
using System.Linq;
using Miucs.Audio;

namespace Miucs.Visualizations;

public sealed class FlightGate
{
    public double X, Center, Velocity, Top, Bottom, Rest, HalfGap;
    public bool Passed;
}
public sealed class FlightParticle
{
    public double X,Y,Vx,Vy,Age,Lifetime;
    public bool Feather;
}
public sealed class FlightPuff
{
    public double X,Y,Age,Strength,Lifetime;
}
/// <summary>Audio-driven flying scene. All randomness is seeded and all collections bounded.</summary>
public sealed class FlightScene
{
    public double Y { get; private set; }=126;
    public double TargetY { get; private set; }=126;
    public double Scale { get; private set; }=.8;
    public double Angle { get; private set; }
    public double Activity { get; private set; }
    public double Flap { get; private set; }
    public double Loudness { get; private set; }
    public double Bass { get; private set; }
    public double Highs { get; private set; }
    public double Brightness { get; private set; }=.5;
    public double Scatter { get; private set; }
    public double Elapsed { get; private set; }
    public double LeadDistance { get; private set; }=250;
    public int Score { get; private set; }
    public string Note => noteAge < .24 && sounding && pitch is int p ? PitchName(p) : "—";
    public List<FlightGate> Gates { get; }=new();
    public List<FlightParticle> Particles { get; }=new();
    public List<FlightPuff> Puffs { get; }=new();
    private Guid session;
    private long sequence, onsetSequence;
    private AudioFeatures? audio;
    private double audioAge=double.PositiveInfinity,noteAge=double.PositiveInfinity,melodyTime=-1,lastTime=-1,rate,mids,velocity,position=126,distance,nextGate,particleBudget,puffCooldown;
    private double lower=48,upper=84;
    private int channels;
    private int? pitch;
    private bool sounding;
    private readonly Random random=new(11621);
    private readonly List<(double Time,double Midi)> history=new();
    public void Reset()
    { session=Guid.Empty;sequence=0;ResetInput();Gates.Clear();Particles.Clear();Puffs.Clear(); }
    private void ResetInput()
    {audio=null;audioAge=noteAge=double.PositiveInfinity;melodyTime=lastTime=-1;pitch=null;history.Clear();lower=48;upper=84;sounding=false;}
    public void Update(AudioInput input,double deltaTime)
    {
        if(!double.IsFinite(deltaTime)||deltaTime<0)return;
        if(session!=input.SessionId){session=input.SessionId;sequence=0;onsetSequence=0;ResetInput();}
        audioAge+=deltaTime;noteAge+=deltaTime;Elapsed+=deltaTime;
        bool live=input.State==AudioState.Running&&input.Frame!=null&&input.FrameAge is >=0 and <.4;
        bool onset=false;double flux=0;
        if(live&&input.Frame is AudioFrame frame)
        {
            if(sequence!=frame.Sequence)
            {
                if(rate!=frame.Audio.SampleRate||channels!=frame.Audio.ChannelCount||frame.Audio.Time<lastTime)
                {ResetInput();rate=frame.Audio.SampleRate;channels=frame.Audio.ChannelCount;}
                audio=frame.Audio;lastTime=audio.Time;sequence=frame.Sequence;audioAge=input.FrameAge??0;
                if(frame.Melody is MelodyFrame melody&&melody.Time>melodyTime)
                {
                    double dt=Math.Clamp(melody.Time-melodyTime,0,.2);melodyTime=melody.Time;
                    if(melody.IsMelodic&&melody.Confidence>=.48&&melody.Midi is double midi&&double.IsFinite(midi)&&midi>=0&&midi<=127)
                    {
                        history.Add((melody.Time,midi));history.RemoveAll(p=>p.Time<melody.Time-30);if(history.Count>2048)history.RemoveAt(0);
                        if(history.Count>=24&&melody.Time-history[0].Time>=3)
                        {
                            var notes=history.Select(p=>p.Midi).OrderBy(p=>p).ToArray();
                            double lo=notes[(int)((notes.Length-1)*.1)]-2,hi=notes[(int)((notes.Length-1)*.9)]+2;
                            double center=(lo+hi)/2,span=Math.Max(12,hi-lo);
                            lower+=Math.Clamp(center-span/2-lower,-dt*.7,dt*.7);upper+=Math.Clamp(center+span/2-upper,-dt*.7,dt*.7);upper=Math.Max(upper,lower+12);
                        }
                        TargetY=196-Math.Clamp((midi-lower)/(upper-lower),0,1)*140;
                        if(pitch==null||Math.Abs(midi-pitch.Value)>.65)pitch=(int)Math.Round(midi);
                        noteAge=(input.FrameAge??0)+Math.Max(0,audio.Time-melody.Time);
                    }
                    else if(!melody.IsMelodic||melody.PitchHz==null)noteAge=double.PositiveInfinity;
                }
            }
            foreach(var ev in input.Onsets)
                if(ev.Sequence>onsetSequence){onset=true;onsetSequence=ev.Sequence;}
            flux=input.SpectralFluxPeak;
        }
        else ResetInput();
        // Real elapsed ages inputs; movement is bounded to avoid long-stall teleportation.
        sounding=audio!=null&&!audio.IsSilent&&audioAge<.4;
        if(sounding&&onset){Flap=1;Emit(true);}
        if(sounding&&flux>.04&&puffCooldown<=0)
        {
            double strength=Math.Clamp((flux-.04)/.56,0,1);
            Puffs.Add(new(){X=96-23*Scale,Y=Y+10*Scale,Strength=strength,Lifetime=.5+strength*.25});if(Puffs.Count>6)Puffs.RemoveAt(0);
            puffCooldown=.14+.2*(1-strength);
        }
        foreach(var p in Puffs)p.Age+=deltaTime;Puffs.RemoveAll(p=>p.Age>=p.Lifetime||p.X<-20);
        foreach(var p in Particles)p.Age+=deltaTime;Particles.RemoveAll(p=>p.Age>=p.Lifetime||p.X<0);
        double duration=Math.Min(deltaTime,.1);int steps=Math.Max(1,(int)Math.Ceiling(duration*120));double step=duration/steps;
        for(int i=0;i<steps;i++)Advance(step);
        puffCooldown=Math.Max(0,puffCooldown-deltaTime);
    }
    private static double Drive(double power)=>Math.Clamp((10*Math.Log10(Math.Max(power,1e-12))+60)/45,0,1);
    private static double Ease(double x){x=Math.Clamp(x,0,1);return x*x*(3-2*x);}
    private void Advance(double dt)
    {
        Activity=Smooth(Activity,sounding?1:0,.28,dt);if(Activity<.002)Activity=0;
        Loudness=Smooth(Loudness,sounding?Drive(Math.Pow(audio?.Envelope??0,2)):0,.1,dt);
        Scale=Smooth(Scale,.8+.6*Loudness,.12,dt);Bass=Smooth(Bass,sounding?Drive(audio?.LowEnergy??0):0,.1,dt);
        mids=Smooth(mids,sounding?Drive(audio?.MidEnergy??0):0,.3,dt);Highs=Smooth(Highs,sounding?Drive(audio?.HighEnergy??0):0,.1,dt);
        Brightness=Smooth(Brightness,Math.Clamp(Math.Log2(Math.Max(audio?.CentroidHz??1000,150)/150)/6,0,1),1.2,dt);
        Scatter=Smooth(Scatter,audio?.Flatness??0,.25,dt);
        LeadDistance=Smooth(LeadDistance,audio?.BandwidthHz is double bw?200+90*Math.Clamp(bw/5000,0,1):250,.45,dt);
        double speed=(96+30*mids)*Activity;distance+=speed*dt;
        Spring(ref position,ref velocity,TargetY,32,dt);Y=position;Angle=Smooth(Angle,Math.Clamp(velocity*.0015,-.28,.28),.055,dt);
        if(sounding&&distance>=nextGate)
        {
            double x=96+LeadDistance;
            if(Gates.Count==0||x-Gates[^1].X>=74)
            {
                double center=72+random.NextDouble()*108,gap=40+random.NextDouble()*8;
                Gates.Add(new(){X=x,Center=center,Rest=center,HalfGap=gap,Top=center-gap,Bottom=center+gap});nextGate=distance+74+random.NextDouble()*16;
            }
        }
        Flap*=Math.Exp(-dt/.14);
        foreach(var gate in Gates)
        {
            gate.X-=speed*dt;double ahead=gate.X-96;
            if(ahead<220)
            {
                double approach=Ease((220-ahead)/130),influence=approach*(1-Ease((-ahead-60)/90));
                double predicted=Math.Clamp(Y+velocity*.045,56,196),target=ahead>=-60?gate.Rest+(predicted-gate.Rest)*approach:gate.Center;
                Spring(ref gate.Center,ref gate.Velocity,Math.Clamp(target,gate.HalfGap+8,238-gate.HalfGap),14,dt);
                double top=gate.Center-gate.HalfGap,bottom=gate.Center+gate.HalfGap,clearance=Scale*(13+25*Math.Abs(Math.Sin(Angle)))+14;
                gate.Top=top+(SoftMin(top,Y-clearance)-top)*influence;gate.Bottom=bottom+(-SoftMin(-bottom,-Y-clearance)-bottom)*influence;
            }
            if(!gate.Passed&&gate.X+30+25*Scale<96){gate.Passed=true;Score++;}
        }
        Gates.RemoveAll(g=>g.X<-70);if(Gates.Count>16)Gates.RemoveAt(0);
        particleBudget+=Highs*24*Activity*dt;if(particleBudget>=1){particleBudget-=1;Emit(false);}
        foreach(var p in Particles){p.X+=(p.Vx-speed*.5)*dt;p.Y+=p.Vy*dt;}
        foreach(var p in Puffs){p.X-=(20+p.Strength*24+speed*.35)*dt;p.Y-=(3+p.Strength*4)*dt;}
    }
    private static string PitchName(int midi)=>new[]{"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"}[midi%12]+(midi/12-1);
    private static void Spring(ref double position,ref double velocity,double target,double frequency,double dt)
    {
        double delta=position-target,impulse=velocity+frequency*delta,decay=Math.Exp(-frequency*dt);
        position=target+(delta+impulse*dt)*decay;velocity=(velocity-frequency*impulse*dt)*decay;
    }
    private static double SoftMin(double a,double b){double h=Math.Max(10-Math.Abs(a-b),0)/10;return Math.Min(a,b)-h*h*2.5;}
    private static double Smooth(double value,double target,double tau,double dt)=>value+(target-value)*(1-Math.Exp(-dt/tau));
    private void Emit(bool feather)
    {
        Particles.Add(new(){X=82,Y=Y+(random.NextDouble()*2-1)*4,Vx=-12-random.NextDouble()*16,Vy=(random.NextDouble()*2-1)*(8+Scatter*35),Lifetime=feather?.65:.9,Feather=feather});
        if(Particles.Count>80)Particles.RemoveAt(0);
    }
}
