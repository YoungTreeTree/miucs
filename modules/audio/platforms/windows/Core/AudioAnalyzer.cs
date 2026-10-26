using System;
using System.Collections.Generic;
using System.Linq;

namespace Miucs.Audio;

/// <summary>Queue-confined streaming PCM analysis. No I/O, UI, or platform dependencies.</summary>
public sealed class AudioAnalyzer
{
    public const int WindowSize = 2048, HopSize = 1024, MelodyWindowSize = 4096;
    private int rate, channels;
    private long samplesSeen;
    private double[][] ring = Array.Empty<double[]>();
    private double envelope, quietDuration, lastOnset = double.NegativeInfinity;
    private bool silent = true, wasAbove;
    private double[]? previousMagnitude;
    private readonly List<double> fluxHistory = new();
    private MelodyAnalyzer melody = new();
    private BeatTracker beat = new();
    private MelodyFrame? latestMelody;

    public void Reset()
    {
        rate = channels = 0; samplesSeen = 0; ring = Array.Empty<double[]>();
        envelope = quietDuration = 0; lastOnset = double.NegativeInfinity; silent = true; wasAbove = false;
        previousMagnitude = null; fluxHistory.Clear(); melody = new(); beat = new(); latestMelody = null;
    }
    public IReadOnlyList<AnalyzedAudio> Process(float[] interleaved, int sampleRate, int channelCount, double receivedAt)
    {
        if (sampleRate < 8000 || sampleRate > 192000 || channelCount < 1 || channelCount > 2 ||
            interleaved.Length % channelCount != 0 || !double.IsFinite(receivedAt) || interleaved.Any(x => !float.IsFinite(x)))
            throw new ArgumentException("Expected finite interleaved mono/stereo PCM at 8–192 kHz.");
        if (interleaved.Length == 0) return Array.Empty<AnalyzedAudio>();
        if (sampleRate != rate || channelCount != channels)
        {
            Reset(); rate = sampleRate; channels = channelCount;
            ring = Enumerable.Range(0, channels).Select(_ => new double[MelodyWindowSize]).ToArray();
        }
        var output = new List<AnalyzedAudio>();
        for (int i = 0; i < interleaved.Length; i += channels)
        {
            int slot = (int)(samplesSeen % MelodyWindowSize);
            for (int c = 0; c < channels; c++) ring[c][slot] = interleaved[i + c];
            samplesSeen++;
            if (samplesSeen < WindowSize || samplesSeen % HopSize != 0) continue;
            if (samplesSeen >= MelodyWindowSize)
                latestMelody = melody.Analyze(ReadWindow(MelodyWindowSize), rate, (samplesSeen - MelodyWindowSize / 2.0) / rate);
            var features = Analyze(ReadWindow(WindowSize));
            output.Add(new AnalyzedAudio(features, latestMelody, receivedAt));
        }
        return output;
    }
    private double[][] ReadWindow(int size)
    {
        var result = new double[channels][];
        for (int c = 0; c < channels; c++)
        {
            result[c] = new double[size];
            for (int j = 0; j < size; j++) result[c][j] = ring[c][(samplesSeen - size + j) % MelodyWindowSize];
        }
        return result;
    }
    private AudioFeatures Analyze(double[][] pcm)
    {
        int n = WindowSize;
        double time = (samplesSeen - n / 2.0) / rate;
        double dt = (samplesSeen == n ? n : HopSize) / (double)rate;
        var sums = new double[channels]; var squares = new double[channels]; double peak = 0;
        for (int c = 0; c < channels; c++) foreach (double x in pcm[c])
        { sums[c] += x; squares[c] += x * x; peak = Math.Max(peak, Math.Abs(x)); }
        double rawPower = squares.Sum() / (n * channels), rms = Math.Sqrt(rawPower), db = 20 * Math.Log10(Math.Max(rms, 1e-12));
        envelope += (rms - envelope) * (1 - Math.Exp(-dt / (rms > envelope ? .025 : .2)));
        if (db < -60) { quietDuration += dt; if (quietDuration >= .15) silent = true; }
        else { quietDuration = 0; if (db >= -54) silent = false; }
        double? balance = null, sideRatio = null, correlation = null;
        if (channels == 2 && rawPower > 1e-12)
        {
            double total = squares.Sum(), cross = 0, side = 0;
            balance = (squares[1] - squares[0]) / total;
            for (int j = 0; j < n; j++) { cross += pcm[0][j] * pcm[1][j]; side += Math.Pow(pcm[0][j] - pcm[1][j], 2) / 4; }
            sideRatio = Math.Clamp(side / (total / 2), 0, 1);
            double vl = Math.Max(0, squares[0] - sums[0] * sums[0] / n), vr = Math.Max(0, squares[1] - sums[1] * sums[1] / n);
            if (vl / n > 1e-12 && vr / n > 1e-12) correlation = Math.Clamp((cross - sums[0] * sums[1] / n) / Math.Sqrt(vl * vr), -1, 1);
        }
        double[] power = Spectrum.Power(pcm, true);
        double binHz = rate / (double)n;
        int lower = Math.Max(1, (int)Math.Ceiling(20 / binHz)), upper = Math.Min(n / 2, (int)Math.Floor(20000 / binHz));
        double maxPower = 0;
        for (int k = lower; k <= upper; k++) maxPower = Math.Max(maxPower, power[k]);
        double floorPower = Math.Max(maxPower * 1e-12, 1e-24), low = 0, mid = 0, high = 0, magSum = 0, weighted = 0, logSum = 0;
        var magnitude = new double[upper - lower + 1];
        for (int k = lower; k <= upper; k++)
        {
            double hz = k * binHz, p = power[k];
            if (hz < 250) low += p; else if (hz < 4000) mid += p; else high += p;
            double m = p >= floorPower ? Math.Sqrt(p) : 0;
            magnitude[k - lower] = m; magSum += m; weighted += m * hz; logSum += Math.Log(Math.Max(p, floorPower));
        }
        double audible = low + mid + high;
        bool valid = audible > 1e-12 && rms > 1e-5;
        double? centroid = null, bandwidth = null, flatness = null;
        if (valid)
        {
            centroid = weighted / magSum; double variance = 0;
            for (int k = lower; k <= upper; k++) variance += magnitude[k - lower] * Math.Pow(k * binHz - centroid.Value, 2);
            bandwidth = Math.Sqrt(variance / magSum);
            flatness = Math.Min(1, Math.Exp(logSum / magnitude.Length) / (audible / magnitude.Length));
        }
        double flux = 0;
        if (previousMagnitude != null && valid && db >= -60)
        {
            for (int j = 0; j < magnitude.Length; j++) flux += Math.Max(0, magnitude[j] - previousMagnitude[j]);
            flux = Math.Min(1, flux / Math.Max(magSum, 1e-12));
        }
        double median = Median(fluxHistory), mad = Median(fluxHistory.Select(x => Math.Abs(x - median)));
        double threshold = Math.Max(.18, median + 4 * 1.4826 * mad);
        bool above = flux >= threshold, onset = previousMagnitude != null && above && !wasAbove && time - lastOnset >= .1;
        if (onset) lastOnset = time;
        wasAbove = above; previousMagnitude = valid ? magnitude : new double[magnitude.Length];
        fluxHistory.Add(flux); int historyLimit = Math.Max(8, rate / HopSize);
        if (fluxHistory.Count > historyLimit) fluxHistory.RemoveRange(0, fluxHistory.Count - historyLimit);
        var bands = new double[24];
        for (int j = 0; j < bands.Length; j++)
        {
            double maxHz = Math.Min(16000, rate / 2.0);
            int start = Math.Clamp((int)Math.Ceiling(40 * Math.Pow(maxHz / 40, j / 24.0) / binHz), 1, power.Length - 1);
            int end = Math.Clamp((int)Math.Ceiling(40 * Math.Pow(maxHz / 40, (j + 1) / 24.0) / binHz), start + 1, power.Length);
            double p = 0; for (int k = start; k < end; k++) p = Math.Max(p, power[k]);
            bands[j] = Math.Clamp((10 * Math.Log10(Math.Max(p, 1e-20)) + 70) / 60, 0, 1);
        }
        return new AudioFeatures
        {
            Time = time, SampleRate = rate, ChannelCount = channels, Rms = rms, RmsDBFS = db, Peak = peak,
            CrestDB = rms > 1e-12 ? 20 * Math.Log10(Math.Max(peak, 1e-12) / rms) : null, Envelope = envelope,
            IsSilent = silent, SilenceDuration = quietDuration, LowEnergy = low, MidEnergy = mid, HighEnergy = high,
            LowShare = valid ? low / audible : null, MidShare = valid ? mid / audible : null, HighShare = valid ? high / audible : null,
            CentroidHz = centroid, BandwidthHz = bandwidth, Flatness = flatness, SpectralFlux = flux, OnsetThreshold = threshold,
            IsOnset = onset, Balance = balance, SideEnergyRatio = sideRatio, Correlation = correlation, DisplayBands = bands,
            Beat = beat.Process(time, flux, low, silent)
        };
    }
    private static double Median(IEnumerable<double> source)
    {
        var values = source.OrderBy(x => x).ToArray(); int count = values.Length;
        return count == 0 ? 0 : count % 2 == 0 ? (values[count / 2 - 1] + values[count / 2]) / 2 : values[count / 2];
    }
}
