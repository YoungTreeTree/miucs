using System;
using System.Collections.Generic;
using System.Linq;
using Miucs.Audio;
using Miucs.Keyboard;

namespace Miucs.Visualizations;

public readonly record struct TracePoint(double Time, double Y, int Segment, double JoinedAt, double JoinDuration);
public readonly record struct StaffStar(double X, double Y, double Radius, double Rotation, double Opacity);

/// <summary>Pure data scene; host time ages effects, distinct PCM time confirms melody.</summary>
public sealed class StaffNoteScene
{
    public double Elapsed { get; private set; }
    public double Y { get; private set; } = 74;
    public double TargetY { get; private set; } = 74;
    public double Scale { get; private set; } = .94;
    public double Sway { get; private set; }
    public double Opacity { get; private set; } = .22;
    public double LabelOpacity { get; private set; }
    public int? Pitch { get; private set; }
    public bool Reliable { get; private set; }
    public bool HasContinuousTraceTail => Reliable && acceptedTime >= 0 &&
        Trace.Count > 0 && Trace[^1].Segment == segment;
    public List<TracePoint> Trace { get; } = new();
    public StaffBeatRings BeatRings { get; } = new();
    public IReadOnlyList<StaffBeatRing> Rings => BeatRings.Rings;
    public KeyboardStars Keyboard { get; } = new();
    private Guid session;
    private long sequence, onsetSequence;
    private double sampleRate, lastAudioTime = -1, melodyTime = -1, acceptedTime = -1, melodyAge = double.PositiveInfinity;
    private int channels, segment, pendingPitch, pendingCount;
    private double pendingTime, lowDb, highDb, volumeTime = -1, contrast = .5;
    private double velocity, angularVelocity, direction = -1;
    private int? referencePitch;
    public static double PitchY(int midi) => 74 - (((midi / 12 - 1) * 7 + new[] { 0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6 }[midi % 12]) - 34) * 4;
    public static string PitchName(int midi) => new[] { "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B" }[midi % 12] + (midi / 12 - 1);
    public void Reset()
    {
        session = Guid.Empty; sequence = 0; ResetAudio(true); Keyboard.Clear();
    }
    private void ResetAudio(bool clear)
    {
        Reliable = false; referencePitch = null; pendingCount = 0; melodyTime = lastAudioTime = acceptedTime = volumeTime = -1;
        melodyAge = double.PositiveInfinity; segment++; angularVelocity = 0; BeatRings.Clear();
        if (clear) Trace.Clear();
    }
    public void Update(AudioInput input, KeyboardInput keyboard, double dt)
    {
        if (!double.IsFinite(dt) || dt < 0) return;
        Elapsed += dt; melodyAge += dt;
        // Expire the previous observation before deciding whether a new point reconnects it.
        if (melodyAge >= .24) Reliable = false;
        Trace.RemoveAll(p => Elapsed - p.Time >= 8);
        Keyboard.Update(keyboard, dt);
        if (session != input.SessionId) { session = input.SessionId; sequence = onsetSequence = 0; sampleRate = 0; ResetAudio(true); }
        var frame = input.Frame;
        bool sounding = input.State == AudioState.Running && frame != null && input.FrameAge is >= 0 and < .4 && !frame.Audio.IsSilent;
        if (sounding && frame != null)
        {
            if (sequence != frame.Sequence)
            {
                var audio = frame.Audio;
                if (sampleRate != audio.SampleRate || channels != audio.ChannelCount || audio.Time < lastAudioTime)
                {
                    bool hadFormat = sampleRate != 0;
                    ResetAudio(true);
                    // Like macOS, discard queued beats from the previous capture format.
                    BeatRings.Clear(hadFormat ? frame.Sequence : 0);
                    sampleRate = audio.SampleRate; channels = audio.ChannelCount;
                }
                sequence = frame.Sequence; lastAudioTime = audio.Time;
                ReceiveVolume(audio.Envelope, audio.Time);
                var melody = frame.Melody;
                double age = (input.FrameAge ?? 0) + (melody == null ? 0 : Math.Max(0, audio.Time - melody.Time));
                if (melody != null && melody.Time > melodyTime)
                {
                    if (melody.Time - melodyTime > .075) pendingCount = 0;
                    melodyTime = melody.Time;
                    if (!melody.IsMelodic || melody.PitchHz == null) { Reliable = false; referencePitch = null; pendingCount = 0; }
                    else if (age < .24 && melody.Confidence >= .48 && melody.Midi is double midi && double.IsFinite(midi) && midi >= 42.5 && midi < 84.5)
                    {
                        int note = referencePitch is int old && Math.Abs(midi - old) <= .65 ? old : (int)Math.Round(midi, MidpointRounding.AwayFromZero);
                        int difference = Math.Abs(note - (referencePitch ?? note));
                        bool accept = difference <= 2;
                        if (!accept)
                        {
                            if (pendingCount == 0 || Math.Abs(note - pendingPitch) > 1) { pendingPitch = note; pendingTime = melody.Time; pendingCount = 0; }
                            pendingCount++;
                            var seconds = difference <= 5 ? .1 : difference <= 10 ? .125 : .15;
                            var count = difference <= 5 ? 2 : difference <= 10 ? 3 : 4;
                            accept = pendingCount >= count && melody.Time - pendingTime + 1e-9 >= seconds;
                        }
                        if (accept)
                        {
                            bool reconnect = !HasContinuousTraceTail;
                            referencePitch = Pitch = note; TargetY = PitchY(note); Reliable = true; melodyAge = age; pendingCount = 0;
                            double y = TargetY, join = 0;
                            if (Trace.Count > 0 && Trace[^1].Segment == segment && acceptedTime >= 0)
                            {
                                double gap = melody.Time - acceptedTime;
                                y = Trace[^1].Y + (TargetY - Trace[^1].Y) * (1 - Math.Exp(-gap / .025));
                                if (reconnect && gap >= .08 - 1e-9) join = .18 + Math.Min(.12, gap * .12);
                            }
                            Trace.Add(new TracePoint(Elapsed - age, y, segment, Elapsed, join));
                            if (Trace.Count > 512) Trace.RemoveAt(0);
                            acceptedTime = melody.Time;
                        }
                    }
                    else pendingCount = 0;
                }
            }
            if (melodyAge >= .24) Reliable = false;
            foreach (var onset in input.Onsets)
            {
                if (onset.Sequence <= onsetSequence) continue;
                onsetSequence = onset.Sequence;
                if (Reliable) { angularVelocity = Math.Clamp(angularVelocity + direction * (6 + Math.Clamp(onset.Strength, 0, 1) * 2), -10.5, 10.5); direction *= -1; }
            }
            BeatRings.Advance(dt, input.Beats, frame.ReceivedAt + (input.FrameAge ?? 0), frame.Sequence);
        }
        else
        {
            if (acceptedTime >= 0) { segment++; acceptedTime = -1; }
            Reliable = false; referencePitch = null; pendingCount = 0; volumeTime = -1; BeatRings.Clear(frame?.Sequence ?? 0);
        }
        if (dt > .25) angularVelocity = 0;
        var step = Math.Min(dt, .25); int steps = Math.Max(1, (int)Math.Ceiling(step * 120)); step /= steps;
        for (int i = 0; i < steps; i++)
        {
            Spring(ref yPosition, ref velocity, TargetY, 40, step); Y = Math.Clamp(yPosition, 14, 146);
            if (sounding && Reliable)
            {
                double start = Sway, sine = Math.Sin(12 * step), cosine = Math.Cos(12 * step), decay = Math.Exp(-5 * step);
                Sway = decay * (start * cosine + (angularVelocity + 5 * start) / 12 * sine);
                angularVelocity = decay * (angularVelocity * cosine - (5 * angularVelocity + 169 * start) / 12 * sine);
            }
            else { double angle = Sway; Spring(ref angle, ref angularVelocity, 0, 30, step); Sway = angle; }
            if (Math.Abs(Sway) > Math.PI / 9) { Sway = Math.CopySign(Math.PI / 9, Sway); if (Sway * angularVelocity > 0) angularVelocity = 0; }
            double ease = 1 - Math.Exp(-step / .055);
            Scale += ((sounding ? .8 + .7 * contrast : .94) - Scale) * ease;
            Opacity += ((Reliable ? .95 : .22) - Opacity) * ease;
            LabelOpacity += ((Reliable ? 1 : 0) - LabelOpacity) * ease;
        }
    }
    private double yPosition = 74;
    private void ReceiveVolume(double envelope, double time)
    {
        if (!double.IsFinite(envelope) || envelope < 0 || time <= volumeTime) return;
        double db = 20 * Math.Log10(Math.Max(envelope, 1e-6));
        if (volumeTime < 0) lowDb = highDb = db;
        else { double ease = 1 - Math.Exp(-(time - volumeTime) / 3); lowDb = Math.Min(db, lowDb + (db - lowDb) * ease); highDb = Math.Max(db, highDb + (db - highDb) * ease); }
        volumeTime = time; contrast = Math.Clamp(.5 + (db - (lowDb + highDb) / 2) / Math.Max(12, highDb - lowDb), 0, 1);
    }
    public static void Spring(ref double position, ref double velocity, double target, double frequency, double dt)
    {
        double delta = position - target, impulse = velocity + frequency * delta, decay = Math.Exp(-frequency * dt);
        position = target + (delta + impulse * dt) * decay; velocity = (velocity - frequency * impulse * dt) * decay;
    }
}

/// <summary>Physical set-1 scan positions; never text, virtual-key translation or a persistent key history.</summary>
public sealed class KeyboardStars
{
    private record Burst(double X, double Y, double Born, bool Small, int Number);
    private readonly List<Burst> bursts = new();
    private readonly Dictionary<ushort, double> holds = new();
    public List<StaffStar> Stars { get; } = new(112);
    private Guid session;
    private long sequence;
    private double elapsed;
    private int number;
    private bool? capsLock;
    public static readonly IReadOnlyDictionary<ushort, (double X, double Y, bool Repeat)> Positions = BuildLayout();
    public void Clear() { bursts.Clear(); Stars.Clear(); holds.Clear(); session = Guid.Empty; sequence = 0; capsLock = null; }
    public void Update(KeyboardInput input, double dt)
    {
        elapsed += dt; bursts.RemoveAll(b => elapsed - b.Born >= .65);
        if (session != input.SessionId) { session = input.SessionId; sequence = 0; holds.Clear(); capsLock = null; }
        if (input.State != KeyboardState.Running) holds.Clear();
        else
        {
            if (input.DroppedEventCount > 0) holds.Clear();
            foreach (var ev in input.Events)
            {
                if (ev.Sequence <= sequence || ev.Sequence > input.Sequence) continue;
                sequence = ev.Sequence;
                double age = input.SampledAt - ev.ReceivedAt;
                if (age < 0 || age > .25 || !Positions.TryGetValue(ev.KeyCode, out var position)) continue;
                if (ev.Kind == KeyboardEventKind.Pressed && position.Repeat && !holds.ContainsKey(ev.KeyCode))
                { Emit(position, elapsed - age, false); holds[ev.KeyCode] = elapsed - age + .3; }
                else if (ev.Kind == KeyboardEventKind.Released) holds.Remove(ev.KeyCode);
                else if (ev.Kind == KeyboardEventKind.ModifiersChanged)
                {
                    if (ev.KeyCode == 0x3A)
                    {
                        bool locked = ev.ModifierIsPressed ?? ((ev.Modifiers & KeyboardModifiers.CapsLock) != 0);
                        if (capsLock != locked) Emit(position, elapsed - age, false);
                        capsLock = locked;
                    }
                    else if (!position.Repeat && ev.ModifierIsPressed == true) Emit(position, elapsed - age, false);
                }
            }
            var held = input.HeldKeys.Select(k => k.KeyCode).ToHashSet();
            foreach (ushort key in holds.Keys.ToArray())
            {
                if (!held.Contains(key)) holds.Remove(key);
                else if (elapsed >= holds[key]) { Emit(Positions[key], elapsed, true); holds[key] = elapsed + .18; }
            }
        }
        sequence = Math.Max(sequence, input.Sequence);
        Stars.Clear();
        foreach (var burst in bursts)
        {
            double age = Math.Max(0, elapsed - burst.Born), t = Math.Clamp(age / .65, 0, 1), travel = 1 - Math.Pow(1 - t, 3);
            if (age < .1) Stars.Add(new(burst.X, burst.Y, (3.5 + 4.5 * travel) * (burst.Small ? .75 : 1), 0, .95 * (1 - age / .1)));
            int count = burst.Small ? 4 : 6;
            for (int i = 0; i < count; i++)
            {
                double angle = i * Math.PI * 2 / count + burst.Number % 17 * .37;
                double distance = (12 + (i * 11 + burst.Number % 13) % 17) * (burst.Small ? .78 : 1);
                double radius = (3 + (i * 7 + burst.Number % 11) % 5 * .5) * (burst.Small ? .76 : 1);
                Stars.Add(new(burst.X + Math.Cos(angle) * distance * travel, burst.Y + Math.Sin(angle) * distance * travel,
                    radius * (1 - t * .15), angle * .3 + (i % 2 == 0 ? .7 : -.6) * t, .9 * Math.Pow(1 - t, 1.4)));
            }
        }
    }
    private void Emit((double X, double Y, bool Repeat) pos, double born, bool small)
    { if (bursts.Count == 16) bursts.RemoveAt(0); bursts.Add(new(pos.X, pos.Y, born, small, ++number)); }
    private static Dictionary<ushort, (double, double, bool)> BuildLayout()
    {
        var result = new Dictionary<ushort, (double, double, bool)>();
        (int, double)[][] rows = {
            new[] {(0x29,1d),(2,1d),(3,1d),(4,1d),(5,1d),(6,1d),(7,1d),(8,1d),(9,1d),(10,1d),(11,1d),(12,1d),(13,1d),(14,2d)},
            new[] {(15,1.5),(16,1d),(17,1d),(18,1d),(19,1d),(20,1d),(21,1d),(22,1d),(23,1d),(24,1d),(25,1d),(26,1d),(27,1d),(43,1.5)},
            new[] {(58,1.75),(30,1d),(31,1d),(32,1d),(33,1d),(34,1d),(35,1d),(36,1d),(37,1d),(38,1d),(39,1d),(40,1d),(28,2.25)},
            new[] {(42,2.25),(44,1d),(45,1d),(46,1d),(47,1d),(48,1d),(49,1d),(50,1d),(51,1d),(52,1d),(53,1d),(54,2.75)},
            new[] {(29,1.5),(0x15B,1.25),(56,1.25),(57,7d),(0x138,1.25),(0x15C,1.25),(0x11D,1.5)}
        };
        var modifiers = new HashSet<int> {58,42,54,29,0x15B,56,0x138,0x15C,0x11D};
        for (int r = 0; r < rows.Length; r++) { double left = 0; foreach (var (code, width) in rows[r]) { result[(ushort)code] = (80 + (left + width / 2) * 680 / 15, 36 + r * 22, !modifiers.Contains(code)); left += width; } }
        return result;
    }
}
