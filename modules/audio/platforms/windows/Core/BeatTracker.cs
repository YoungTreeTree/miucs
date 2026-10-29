using System;
using System.Collections.Generic;
using System.Linq;

namespace Miucs.Audio;

/// <summary>Causal 50 Hz novelty autocorrelation and phase-locked pulse clock.</summary>
internal sealed class BeatTracker
{
    private const double Step = .02;
    private readonly List<double> values = new();
    private double gridTime, nextGridTime, lastNovelty, previousLow, previousGrid, olderGrid, fluxMean;
    private double? lastTime, period, nextBeat, proposedPeriod;
    private double lastActivity = double.NegativeInfinity, lastAnalysis = double.NegativeInfinity;
    private double lastBeat = double.NegativeInfinity, score, lastSupport = double.NegativeInfinity;
    private int proposedCount;

    private void Reset()
    {
        values.Clear(); gridTime = nextGridTime = lastNovelty = previousLow = previousGrid = olderGrid = fluxMean = 0;
        lastTime = period = nextBeat = proposedPeriod = null; proposedCount = 0;
        lastActivity = lastAnalysis = lastBeat = lastSupport = double.NegativeInfinity; score = 0;
    }
    public BeatFrame Process(double time, double flux, double lowEnergy, bool silent)
    {
        if (lastTime == time) return Empty(time);
        if (lastTime.HasValue && (time < lastTime || time - lastTime > .2)) Reset();
        if (silent && time - lastActivity > 2.5) { Reset(); return Empty(time); }
        if (!lastTime.HasValue)
        { lastTime = time; nextGridTime = time; previousLow = lowEnergy; fluxMean = flux; lastActivity = time; return Empty(time); }
        double previousTime = lastTime.Value, dt = time - previousTime;
        double lowRise = Math.Clamp(Math.Log10((lowEnergy + 1e-12) / (previousLow + 1e-12)), 0, 1);
        double novelty = silent ? 0 : Math.Max(0, flux - 1.15 * fluxMean - .015) + .20 * lowRise;
        fluxMean += (flux - fluxMean) * (1 - Math.Exp(-dt / .7)); previousLow = lowEnergy;
        if (novelty > .045) lastActivity = time;
        while (nextGridTime <= time + 1e-9)
        {
            double fraction = Math.Clamp((nextGridTime - previousTime) / dt, 0, 1);
            double raw = lastNovelty + (novelty - lastNovelty) * fraction;
            values.Add(.25 * olderGrid + .5 * previousGrid + .25 * raw);
            olderGrid = previousGrid; previousGrid = raw; gridTime = nextGridTime; nextGridTime += Step;
        }
        if (values.Count > 400) values.RemoveRange(0, values.Count - 400);
        lastTime = time; lastNovelty = novelty;
        if (time - lastAnalysis >= .25 && values.Count >= 110) { Analyze(time); lastAnalysis = time; }
        if (!period.HasValue || !nextBeat.HasValue) return Empty(time);
        double p = period.Value, next = nextBeat.Value;
        double nearest = next + Math.Round((time - next) / p) * p;
        if (Math.Abs(time - nearest) < Math.Min(.1, p * .2) && novelty > .045) lastSupport = time;
        double coast = Math.Max(0, time - lastSupport - p * 1.2);
        double confidence = Math.Clamp(score * Math.Exp(-coast / Math.Max(.15, p * .5)), 0, 1);
        if (time - lastActivity >= Math.Max(.8, p * 1.8) || confidence < .45)
        { nextBeat = null; return new BeatFrame(time, null, null, confidence, 0, null); }
        double? due = null;
        if (time >= next && (!silent || time - next > .08))
        {
            if (!silent && time - next <= .08 && next - lastBeat >= p * .55) { due = next; lastBeat = next; }
            nextBeat = next + Math.Max(1, Math.Floor((time - next) / p) + 1) * p;
        }
        double phase = ((time - next) / p) % 1;
        double recent = values.TakeLast(5).DefaultIfEmpty(0).Max(), peak = Math.Max(.08, values.DefaultIfEmpty(.08).Max());
        double strength = Math.Clamp(recent / peak, .2, 1);
        return silent ? Empty(time) : new BeatFrame(time, 60 / p, phase < 0 ? phase + 1 : phase, confidence, strength, due);
    }
    private void Analyze(double time)
    {
        double mean = values.Average(); var centered = values.Select(v => v - mean).ToArray();
        const int minLag = 15, maxLag = 60;
        var correlations = new double[maxLag + 2];
        for (int lag = minLag - 1; lag <= maxLag + 1; lag++)
        {
            double cross = 0, first = 0, second = 0;
            for (int i = lag; i < centered.Length; i++)
            { double a = centered[i], b = centered[i - lag]; cross += a * b; first += a * a; second += b * b; }
            correlations[lag] = cross / Math.Max(1e-10, Math.Sqrt(first * second));
        }
        var candidates = new List<(double Period, double Correlation)>();
        for (int lag = minLag; lag <= maxLag; lag++)
        {
            double value = correlations[lag];
            if (value <= .35 || value < correlations[lag - 1] || value < correlations[lag + 1]) continue;
            double denominator = correlations[lag - 1] - 2 * value + correlations[lag + 1];
            double offset = Math.Abs(denominator) > 1e-9 ? Math.Clamp(.5 * (correlations[lag - 1] - correlations[lag + 1]) / denominator, -.5, .5) : 0;
            double interval = Math.Clamp((lag + offset) * Step, .3, 1.2);
            if (values.Count * Step >= interval * 3) candidates.Add((interval, value));
        }
        if (candidates.Count == 0) { score *= .75; proposedPeriod = null; proposedCount = 0; return; }
        var best = candidates.MaxBy(c => c.Correlation);
        foreach (var candidate in candidates.OrderBy(c => c.Period))
        {
            if (candidate.Period >= best.Period) continue;
            double ratio = best.Period / candidate.Period;
            if (Math.Abs(ratio - Math.Round(ratio)) < .08 && Math.Round(ratio) >= 2 && candidate.Correlation >= best.Correlation * .85)
            { best = candidate; break; }
        }
        if (period.HasValue)
            foreach (var stable in candidates)
                if (Math.Abs(stable.Period / period.Value - 1) < .06 && stable.Correlation >= best.Correlation * .92) { best = stable; break; }
        if (!period.HasValue && best.Correlation < .38) { proposedPeriod = null; proposedCount = 0; return; }
        if (!period.HasValue || Math.Abs(best.Period / period.Value - 1) > .08)
        {
            if (proposedPeriod.HasValue && Math.Abs(best.Period / proposedPeriod.Value - 1) < .05) proposedCount++;
            else { proposedPeriod = best.Period; proposedCount = 1; }
            if (proposedCount < 3) { score *= .9; return; }
            period = best.Period; nextBeat = null;
        }
        else period += (best.Period - period.Value) * .25;
        proposedCount = 0; proposedPeriod = null; score = best.Correlation;
        double p = period.Value, lagSamples = p / Step;
        int bestOffset = 0; double bestEnergy = double.NegativeInfinity;
        for (int offset = 0; offset < Math.Ceiling(lagSamples); offset++)
        {
            double energy = 0, weight = 1, total = 0;
            for (int cycle = 0; cycle < 8; cycle++)
            {
                double index = values.Count - 1 - offset - cycle * lagSamples;
                if (index < 1) break;
                energy += Sample(index) * weight; total += weight; weight *= .85;
            }
            energy /= Math.Max(1, total);
            if (energy > bestEnergy) { bestEnergy = energy; bestOffset = offset; }
        }
        double anchor = gridTime - bestOffset * Step;
        if (bestEnergy <= Math.Max(.04, mean * 1.5)) { score *= .5; return; }
        if (nextBeat.HasValue)
        {
            double aligned = anchor + Math.Round((nextBeat.Value - anchor) / p) * p;
            nextBeat += Math.Clamp((aligned - nextBeat.Value) * .3, -.02, .02);
        }
        else if (time - lastActivity < p * 1.5)
        { nextBeat = time - anchor < .06 && anchor - lastBeat >= p * .55 ? anchor : anchor + p; lastSupport = anchor; }
    }
    private double Sample(double index)
    {
        int lower = Math.Clamp((int)index, 0, values.Count - 1), upper = Math.Min(values.Count - 1, lower + 1);
        return values[lower] + (values[upper] - values[lower]) * (index - lower);
    }
    private static BeatFrame Empty(double time) => new(time, null, null, 0, 0, null);
}
