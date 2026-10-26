using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Miucs.Audio;

public static class AudioTests
{
    public static void ExportReference(string pcmPath, string outputPath)
    {
        byte[] bytes = File.ReadAllBytes(pcmPath);
        if (bytes.Length % 8 != 0) throw new ArgumentException("Expected Float32 stereo PCM.");
        var samples = new float[bytes.Length / 4];
        Buffer.BlockCopy(bytes, 0, samples, 0, bytes.Length);
        var frames = new AudioAnalyzer().Process(samples, 48000, 2, 100);
        File.WriteAllText(outputPath, JsonSerializer.Serialize(frames.Select(f => f.Audio), AudioContract.JsonOptions));
    }
    private static int checks;
    private static void Check(bool ok, string message) { if (!ok) throw new Exception(message); checks++; }
    private static void Near(double actual, double expected, double tolerance, string message) => Check(Math.Abs(actual - expected) <= tolerance, $"{message}: {actual} vs {expected}");
    private static float[] Tone(int rate, double seconds, double hz = 440, double amplitude = .5, int channels = 1, bool antiPhase = false)
    {
        var data = new float[(int)(rate * seconds) * channels];
        for (int i = 0; i < data.Length / channels; i++) for (int c = 0; c < channels; c++)
            data[i * channels + c] = (float)(amplitude * Math.Sin(2 * Math.PI * hz * i / rate) * (antiPhase && c == 1 ? -1 : 1));
        return data;
    }
    private static List<AnalyzedAudio> Analyze(float[] data, int rate = 48000, int channels = 1, int blockFrames = 511)
    {
        var analyzer = new AudioAnalyzer(); var output = new List<AnalyzedAudio>();
        int block = blockFrames * channels;
        for (int i = 0; i < data.Length; i += block)
            output.AddRange(analyzer.Process(data.Skip(i).Take(Math.Min(block, data.Length - i)).ToArray(), rate, channels, 100 + i / (double)(rate * channels)));
        return output;
    }
    public static void Run()
    {
        checks = 0;
        foreach (int rate in new[] { 44100, 48000, 96000 })
        {
            var frames = Analyze(Tone(rate, .6), rate);
            var frame = frames[^1];
            Near(frame.Audio.Rms, .5 / Math.Sqrt(2), .003, "Sine RMS");
            Near(frame.Audio.CentroidHz!.Value, 440, rate / 2048.0 * .2, "Frequency uses actual rate");
            Check(frame.Melody is { IsMelodic: true, PitchHz: not null }, "Melody is present");
            Near(frame.Melody!.PitchHz!.Value, 440, 4, "Harmonic pitch");
            Check(frame.Audio.DisplayBands.Count == 24 && frame.Audio.DisplayBands.All(x => x >= 0 && x <= 1), "Display bands");
            Check(frames.All(x => !x.Audio.IsOnset), "Steady sine must not repeatedly onset");
        }
        var stereo = Analyze(Tone(48000, .4, channels: 2, antiPhase: true), channels: 2)[^1];
        Near(stereo.Audio.Correlation!.Value, -1, 1e-10, "Antiphase correlation");
        Near(stereo.Audio.SideEnergyRatio!.Value, 1, 1e-10, "Antiphase width");
        Near(stereo.Audio.CentroidHz!.Value, 440, 3, "Antiphase preserves spectrum");
        Check(stereo.Melody is { IsMelodic: true }, "Antiphase preserves melody");
        var mono = Analyze(Tone(48000, .2))[^1].Audio;
        Check(mono.Correlation == null && mono.Balance == null && mono.SideEnergyRatio == null, "Mono missing stereo values");
        var silence = Analyze(new float[48000]);
        Check(silence.All(f => f.Audio.IsSilent && f.Audio.Rms == 0 && f.Audio.RmsDBFS == -240 && f.Audio.CrestDB == null && f.Audio.CentroidHz == null), "Silence missing values");
        Check(silence[^1].Melody is { IsMelodic: false, PitchHz: null }, "Silence has no invented pitch");
        var loud = Analyze(Tone(48000, .2, amplitude: 2))[^1].Audio;
        Check(loud.Peak > 1.99 && loud.Rms > 1.4, "Unclipped PCM measurements");
        var quietPitch = Analyze(Tone(48000, .4, amplitude: .01))[^1].Melody;
        Check(quietPitch is { IsMelodic: true }, "Pitch survives gain reduction");
        Near(quietPitch!.PitchHz!.Value, 440, 4, "Amplitude does not set pitch");
        var harmonic = new float[24000];
        for (int i = 0; i < harmonic.Length; i++) harmonic[i] = (float)(.08 * Math.Sin(2 * Math.PI * 220 * i / 48000) + .3 * Math.Sin(2 * Math.PI * 440 * i / 48000) + .2 * Math.Sin(2 * Math.PI * 660 * i / 48000));
        var harmonicPitch = Analyze(harmonic)[^1].Melody;
        Check(harmonicPitch is { IsMelodic: true }, "Harmonic mixture is tonal");
        Near(harmonicPitch!.PitchHz!.Value, 220, 4, "Harmonic support recovers weak fundamental");
        var noise = new float[48000]; var random = new Random(20261026);
        for (int i = 0; i < noise.Length; i++) noise[i] = (float)((random.NextDouble() * 2 - 1) * .2);
        var noiseFrames = Analyze(noise);
        Check(noiseFrames.Count(f => f.Melody?.IsMelodic == true) == 0, "White noise must not fabricate melody");
        Check(noiseFrames[^1].Audio.Flatness > .3, "Noise spectrum is flatter than a sine");
        var mix = new float[48000];
        for (int i = 0; i < mix.Length; i++) mix[i] = (float)(.3 * Math.Sin(2 * Math.PI * 93.75 * i / 48000) + .2 * Math.Sin(2 * Math.PI * 1500 * i / 48000) + .1 * Math.Sin(2 * Math.PI * 6000 * i / 48000));
        var mixed = Analyze(mix)[^1].Audio;
        Near(mixed.LowShare!.Value, 9.0 / 14, .005, "Low power share");
        Near(mixed.MidShare!.Value, 4.0 / 14, .005, "Mid power share");
        Near(mixed.HighShare!.Value, 1.0 / 14, .005, "High power share");
        var small = Analyze(mix, blockFrames: 137); var large = Analyze(mix, blockFrames: 8192);
        Check(small.Count == large.Count, "Chunk-independent frame count");
        for (int i = 0; i < small.Count; i++)
        {
            Near(small[i].Audio.Rms, large[i].Audio.Rms, 0, "Chunk-independent RMS");
            Near(small[i].Audio.Time, large[i].Audio.Time, 0, "Chunk-independent timeline");
            Check(small[i].Melody == large[i].Melody, "Chunk-independent melody pairing");
        }
        var analyzer = new AudioAnalyzer();
        analyzer.Process(Tone(48000, .2), 48000, 1, 1);
        var fresh = analyzer.Process(Tone(44100, 2048.0 / 44100), 44100, 1, 2);
        Check(fresh.Count == 1 && fresh[0].Melody == null, "Format change clears melody history");
        Near(fresh[0].Audio.Time, 1024.0 / 44100, 1e-12, "Format timeline resets");
        bool rejected = false;
        try { analyzer.Process(new[] { float.NaN }, 48000, 1, 2); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "Reject nonfinite PCM");
        rejected = false;
        try { analyzer.Process(new float[4], 48000, 3, 2); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "Reject unsupported channel count");
        ChannelTests(); ContractTests(); BeatTests();
        Console.WriteLine($"Audio core: {checks} assertions passed.");
    }
    private static void ChannelTests()
    {
        var channel = new AudioChannel(); var session = channel.BeginSession(AudioState.Running);
        using var one = channel.Subscribe(); using var two = channel.Subscribe();
        var audio = new AudioFeatures { SampleRate = 48000, ChannelCount = 1, IsOnset = true, SpectralFlux = .9, Time = .1 };
        Check(channel.Publish(session, audio, null, 1), "Publish current generation");
        channel.Publish(session, audio with { IsOnset = false, SpectralFlux = .1 }, null, 1.01);
        var first = one.Read(1.02);
        Check(first.Onsets.Count == 1 && first.SpectralFluxPeak == .9 && first.Frame!.Sequence == 2, "Retain short transient over latest frame");
        Check(one.Read(1.03).Onsets.Count == 0 && one.Read(1.03).SpectralFluxPeak == 0, "Read-once events");
        Check(two.Read(1.03).Onsets.Count == 1, "Independent subscriber cursor");
        using var fresh = channel.Subscribe();
        Check(fresh.Read(1.04).Onsets.Count == 0, "New subscription skips history");
        for (int i = 0; i < 100; i++) channel.Publish(session, audio, null, 2 + i * .001);
        Check(one.Read(2.1).Onsets.Count == 64, "Event queue capacity");
        Check(two.Read(2.5).Onsets.Count == 0, "Event expiration");
        session = channel.BeginSession(AudioState.Running);
        Check(!channel.Publish(first.SessionId, audio, null, 3), "Reject late old-generation frame");
        Check(!channel.SetState(first.SessionId, AudioState.Recovering), "Reject late old-generation state");
        Check(one.Read(3).Frame == null, "Reset removes stale frame");
        channel.Publish(session, audio, null, 4);
        channel.Publish(session, audio with { IsSilent = true, IsOnset = false }, null, 4.01);
        Check(one.Read(4.02).Onsets.Count == 1, "Quiet snapshot preserves short unread onset");
        channel.Publish(session, audio, null, 5);
        channel.Publish(session, audio with { SampleRate = 44100, IsOnset = false, SpectralFlux = 0 }, null, 5.01);
        Check(one.Read(5.02).Onsets.Count == 0, "Format change clears old events");
        Parallel.For(0, 1000, i => { using var reader = channel.Subscribe(); reader.Read(6); });
        Check(true, "Concurrent subscriptions and reads");
        session = channel.BeginSession(AudioState.Running);
        Parallel.Invoke(
            () => { for (int i = 0; i < 1000; i++) channel.Publish(session, audio, null, 10); },
            () => { for (int i = 0; i < 1000; i++) one.Read(10.1); },
            () => { for (int i = 0; i < 1000; i++) two.Read(10.1); });
        Check(one.Read(10.1).Frame?.Sequence == 1000, "Concurrent publication retains final snapshot");
        var beatAudio = audio with { IsOnset = false, Time = 1, Beat = new BeatFrame(1, 120, 0, .8, .6, .9) };
        channel.Publish(session, beatAudio, null, 11);
        var pulse = one.Read(11.01);
        Check(pulse.Beats.Count == 1, "Independent beat event is retained");
        Near(pulse.Beats[0].ReceivedAt, 10.9, 1e-12, "Beat receipt backdates only PCM offset");
        channel.Publish(session, beatAudio, null, 11.015);
        Check(one.Read(11.02).Beats.Count == 0, "Repeated beat time is not emitted twice");
        channel.SetState(AudioState.Recovering);
        Check(two.Read(11.02).Beats.Count == 0, "Recovery clears queued beats");
        Check(!channel.Publish(session, audio, null, 12), "No publication while recovering");
        session = channel.BeginSession(AudioState.Running);
        using var peakReader = channel.Subscribe();
        for (int i = 0; i < 1000; i++) channel.Publish(session, audio with { SpectralFlux = 1 - i / 1001.0 }, null, 20 + i * .0001);
        Near(peakReader.Read(20.1).SpectralFluxPeak, 1, 0, "Large descending burst retains unread maximum");
    }
    private static void ContractTests()
    {
        string? root = Directory.GetCurrentDirectory();
        while (root != null && !Directory.Exists(Path.Combine(root, "contracts", "audio-features", "samples"))) root = Directory.GetParent(root)?.FullName;
        if (root == null) throw new Exception("Run tests from the repository so contract fixtures can be checked.");
        foreach (string path in Directory.GetFiles(Path.Combine(root, "contracts", "audio-features", "samples"), "*.json"))
        {
            var input = AudioContract.ReadInput(File.ReadAllText(path));
            Check(input.SessionId != Guid.Empty, "Contract sample UUID");
            string json = AudioContract.WriteInput(input);
            using var doc = JsonDocument.Parse(json);
            Check(doc.RootElement.TryGetProperty("sessionID", out _), "Exact JSON sessionID spelling");
            var again = AudioContract.ReadInput(json);
            Check(again.State == input.State && again.Frame?.Sequence == input.Frame?.Sequence, "Contract round trip");
        }
    }
    private static void BeatTests()
    {
        // Raw synthetic PCM clicks, no injected onset/beat metadata.
        int rate = 24000; var pcm = new float[rate * 12];
        for (int i = 0; i < pcm.Length; i++)
        {
            double local = (i / (double)rate) % .5;
            if (local < .09) pcm[i] = (float)(.7 * Math.Exp(-local * 45) * Math.Sin(2 * Math.PI * 120 * i / rate));
        }
        var frames = Analyze(pcm, rate);
        var locked = frames.Where(x => x.Audio.Time > 6 && x.Audio.Beat?.Bpm != null).ToArray();
        Check(locked.Length > 20, "Beat tracker locks to synthetic PCM pulse train");
        Near(locked.Average(x => x.Audio.Beat!.Bpm!.Value), 120, 3, "Synthetic pulse BPM");
        Check(frames.Count(x => x.Audio.Beat?.BeatTime != null) >= 8, "Beat tracker emits independent pulses");
    }
}
