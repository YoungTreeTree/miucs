using System;
using System.Collections.Generic;
using Miucs.Audio;

namespace Miucs.Visualizations;

public enum StaffBeatArc { Main, Satellite }
public readonly record struct StaffBeatRing(double X, double Y, double Radius, double Opacity,
    double LineWidth = 1.05, double Rotation = 0, StaffBeatArc Arc = StaffBeatArc.Main);

/// <summary>Port of core/StaffBeatRings.swift: independent beat lifetimes and cached random origins.</summary>
public sealed class StaffBeatRings
{
    public const int PulseLimit = 4, Limit = PulseLimit * 5;
    public const double Lifetime = .89, MaximumEventAge = .15;
    public const double MinX = 112, MaxX = 712, MinY = 48, MaxY = 112;
    private readonly record struct Satellite(double Dx, double Dy, double Radius, double Angle);
    private sealed record Pulse(double Born, double Strength, double X, double Y, double Phase, Satellite[] Satellites);
    private readonly List<Pulse> pulses = new(PulseLimit);
    private readonly List<StaffBeatRing> rings = new(Limit);
    public IReadOnlyList<StaffBeatRing> Rings => rings;
    public long TotalPulses { get; private set; }
    private ulong randomState;
    private double? previousX;
    private double elapsed;
    private long sequence;

    public StaffBeatRings(ulong? seed = null) => randomState = seed ?? (ulong)Random.Shared.NextInt64();
    public void Clear(long through = 0)
    {
        pulses.Clear(); rings.Clear(); elapsed = 0; sequence = through; TotalPulses = 0; previousX = null;
    }
    public void Advance(double seconds, IReadOnlyList<BeatEvent> events, double now, long through)
    {
        if (double.IsFinite(seconds) && seconds > 0) elapsed += seconds;
        pulses.RemoveAll(p => elapsed - p.Born >= Lifetime);
        foreach (var beat in events)
        {
            if (beat.Sequence <= sequence || beat.Sequence > through) continue;
            sequence = beat.Sequence;
            double age = now - beat.ReceivedAt;
            if (!double.IsFinite(age) || age < 0 || age > MaximumEventAge ||
                !double.IsFinite(beat.Strength) || beat.Strength is < 0 or > 1 ||
                !double.IsFinite(beat.Confidence) || beat.Confidence is < .45 or > 1 ||
                !double.IsFinite(beat.Bpm) || beat.Bpm is < 50 or > 200) continue;
            if (pulses.Count == PulseLimit) pulses.RemoveAt(0);
            var (x, y) = NextOrigin();
            double phase = RandomUnit() * 2 * Math.PI;
            var satellites = new Satellite[3];
            for (int i = 0; i < satellites.Length; i++)
            {
                double angle = phase * 1.31 + (i == 0 ? .4 : i == 1 ? 2.5 : 4.55), distance = 28 + i * 6;
                satellites[i] = new(Math.Cos(angle) * distance, Math.Sin(angle) * distance * .8,
                    i == 0 ? 6.2 : i == 1 ? 8.3 : 5.3, angle);
            }
            pulses.Add(new(elapsed - age, beat.Strength, x, y, phase, satellites));
            TotalPulses++;
        }
        sequence = Math.Max(sequence, through);
        rings.Clear();
        foreach (var pulse in pulses)
        {
            double age = elapsed - pulse.Born;
            for (int layer = 0; layer < 2; layer++)
            {
                double localAge = age - layer * .09;
                if (localAge < 0 || localAge >= .8) continue;
                double t = localAge / .8, expansion = 1 - Math.Pow(1 - t, 3);
                rings.Add(new(pulse.X, pulse.Y, 4 + (layer == 0 ? 28 : 20) * expansion,
                    Math.Min(1, localAge / .035) * Math.Pow(1 - t, 1.1) * (layer == 0 ? .73 : .48) * (.85 + .15 * pulse.Strength),
                    layer == 0 ? 1.05 : .72, pulse.Phase + layer * .2));
            }
            for (int i = 0; i < pulse.Satellites.Length; i++)
            {
                var satellite = pulse.Satellites[i];
                double localAge = age - .10 - i * .055;
                if (localAge < 0 || localAge >= .58) continue;
                double t = localAge / .58, expansion = 1 - Math.Pow(1 - t, 3), travel = .7 + .3 * expansion;
                rings.Add(new(pulse.X + satellite.Dx * travel, pulse.Y + satellite.Dy * travel,
                    1.5 + (satellite.Radius - 1.5) * expansion,
                    Math.Min(1, localAge / .06) * .55 * Math.Pow(1 - t, 1.2) * (.85 + .15 * pulse.Strength),
                    .65, satellite.Angle, StaffBeatArc.Satellite));
            }
        }
    }
    private (double X, double Y) NextOrigin()
    {
        double width = MaxX - MinX, x = MinX + RandomUnit() * width;
        if (previousX is double old && Math.Abs(x - old) < 120) x = MinX + (x - MinX + width / 2) % width;
        previousX = x;
        return (x, MinY + RandomUnit() * (MaxY - MinY));
    }
    private double RandomUnit()
    {
        randomState = unchecked(randomState * 6364136223846793005UL + 1442695040888963407UL);
        return (randomState >> 11) / 9_007_199_254_740_992d;
    }
}
