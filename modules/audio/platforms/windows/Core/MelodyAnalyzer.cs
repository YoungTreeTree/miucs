using System;
using System.Collections.Generic;
using System.Linq;

namespace Miucs.Audio;

/// <summary>Port of the native harmonic-salience mixed-audio melody estimator.</summary>
internal sealed class MelodyAnalyzer
{
    private double? previousMidi;
    private double lastReliable = double.NegativeInfinity;
    private sealed record Peak(double Hz, double Magnitude);
    public MelodyFrame Analyze(double[][] pcm, int rate, double time)
    {
        MelodyFrame Absent(double confidence = 0)
        {
            if (time - lastReliable > .35) previousMidi = null;
            return new MelodyFrame(time, null, confidence, false);
        }
        int n = pcm[0].Length;
        double energy = 0;
        foreach (var c in pcm) foreach (double x in c) energy += x * x;
        if (Math.Sqrt(energy / (n * pcm.Length)) <= .0005) return Absent();
        var power = Spectrum.Power(pcm, false); double binHz = rate / (double)n;
        int first = Math.Max(2, (int)(60 / binHz)), last = Math.Min(n / 2 - 2, (int)(8000 / binHz));
        double maximum = 0, total = 0;
        for (int k = first; k <= last; k++) { maximum = Math.Max(maximum, power[k]); total += power[k]; }
        if (maximum <= 0) return Absent();
        var peaks = new List<Peak>();
        for (int k = first; k <= last; k++)
        {
            if (power[k] <= power[k - 1] || power[k] < power[k + 1] || power[k] <= maximum * .0001) continue;
            double a = Math.Log(Math.Max(power[k - 1], 1e-24)), b = Math.Log(Math.Max(power[k], 1e-24)), c = Math.Log(Math.Max(power[k + 1], 1e-24));
            double denominator = a - 2 * b + c;
            double delta = Math.Abs(denominator) > 1e-12 ? Math.Clamp(.5 * (a - c) / denominator, -.5, .5) : 0;
            peaks.Add(new Peak((k + delta) * binHz, Math.Sqrt(power[k])));
        }
        peaks = peaks.OrderByDescending(p => p.Magnitude).Take(60).ToList();
        double selected = 0;
        foreach (var p in peaks)
        {
            int k = Math.Clamp((int)Math.Round(p.Hz / binHz), first, last);
            selected += power[k - 1] + power[k] + power[k + 1];
        }
        double tonality = Math.Min(selected / Math.Max(total, 1e-12), 1);
        if (tonality <= .42 || peaks.Count == 0) return Absent();
        var cumulative = new double[power.Length + 1];
        for (int k = 0; k < power.Length; k++) cumulative[k + 1] = cumulative[k] + power[k];
        for (int i = 0; i < peaks.Count; i++)
        {
            var p = peaks[i]; double radius = Math.Max(100, p.Hz * .3);
            int lo = Math.Max(1, (int)((p.Hz - radius) / binHz)), hi = Math.Min(power.Length - 1, (int)((p.Hz + radius) / binHz));
            double local = (cumulative[hi + 1] - cumulative[lo]) / (hi - lo + 1);
            peaks[i] = p with { Magnitude = p.Magnitude * Math.Pow(Math.Max(local / maximum, .0001), -.1) };
        }
        peaks.Sort((a, b) => b.Magnitude.CompareTo(a.Magnitude));
        double strongest = peaks[0].Magnitude;
        const int bins = 561;
        var salience = new double[bins];
        foreach (var p in peaks)
        {
            double strength = Math.Pow(p.Magnitude / strongest, 1.2);
            for (int h = 1; h <= 10; h++)
            {
                double midi = 69 + 12 * Math.Log2(p.Hz / h / 440), position = (midi - 40) * 10;
                if (position < 0 || position > bins - 1) continue;
                int center = (int)Math.Round(position);
                for (int i = Math.Max(0, center - 3); i <= Math.Min(bins - 1, center + 3); i++)
                    salience[i] += strength * Math.Pow(.8, h - 1) * Math.Exp(-2 * Math.Pow((i - position) / 3, 2));
            }
        }
        var candidates = new List<(double Midi, double Score, double Support)>();
        for (int i = 1; i < bins - 1; i++)
        {
            if (salience[i] <= salience[i - 1] || salience[i] < salience[i + 1]) continue;
            double midi = 40 + i / 10.0, hz = 440 * Math.Pow(2, (midi - 69) / 12), fundamental = 0, odd = 0, matching = 0;
            foreach (var p in peaks)
            {
                int harmonic = (int)Math.Round(p.Hz / hz);
                if (harmonic < 1 || harmonic > 10) continue;
                double cents = Math.Abs(1200 * Math.Log2(p.Hz / (hz * harmonic)));
                if (cents >= 40) continue;
                double strength = p.Magnitude / strongest; matching += strength;
                if (harmonic == 1) fundamental = Math.Max(fundamental, strength);
                if (harmonic % 2 == 1) odd += strength;
            }
            double penalty = fundamental < .04 && odd < .08 ? .28 : 1;
            double register = midi < 48 ? .62 : midi > 88 ? .8 : 1;
            candidates.Add((midi, salience[i] * penalty * register, Math.Min(matching, 1)));
        }
        if (candidates.Count == 0) return Absent();
        double maximumScore = candidates.Max(c => c.Score);
        if (maximumScore <= 0) return Absent();
        var chosen = candidates.Where(c => c.Score >= maximumScore * .55)
            .MaxBy(c => c.Score / maximumScore - (previousMidi.HasValue ? Math.Min(Math.Abs(c.Midi - previousMidi.Value) * .025, .24) : 0));
        double confidence = Math.Clamp((tonality - .35) / .55, 0, 1) * Math.Min(1, chosen.Score / maximumScore) * chosen.Support;
        if (confidence < .48) return Absent(confidence);
        previousMidi = chosen.Midi; lastReliable = time;
        return new MelodyFrame(time, 440 * Math.Pow(2, (chosen.Midi - 69) / 12), confidence, true);
    }
}
