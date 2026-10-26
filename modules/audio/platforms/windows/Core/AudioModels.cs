using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Miucs.Audio;

public enum AudioState { Stopped, Connecting, Running, Recovering, Suspended, PermissionRequired, UserStopped }

public sealed record BeatFrame(double Time, double? Bpm, double? Phase, double Confidence, double Strength, double? BeatTime);
public sealed record MelodyFrame(double Time, double? PitchHz, double Confidence, bool IsMelodic)
{
    [JsonIgnore] public double? Midi => PitchHz is > 0 ? 69 + 12 * Math.Log2(PitchHz.Value / 440) : null;
}

/// <summary>Contract v1 measurements, not UI gain values. Missing measurements are null.</summary>
public sealed record AudioFeatures
{
    public double Time { get; init; }
    public double SampleRate { get; init; }
    public int ChannelCount { get; init; }
    public double Rms { get; init; }
    public double RmsDBFS { get; init; }
    public double Peak { get; init; }
    public double? CrestDB { get; init; }
    public double Envelope { get; init; }
    public bool IsSilent { get; init; }
    public double SilenceDuration { get; init; }
    public double LowEnergy { get; init; }
    public double MidEnergy { get; init; }
    public double HighEnergy { get; init; }
    public double? LowShare { get; init; }
    public double? MidShare { get; init; }
    public double? HighShare { get; init; }
    public double? CentroidHz { get; init; }
    public double? BandwidthHz { get; init; }
    public double? Flatness { get; init; }
    public double SpectralFlux { get; init; }
    public double OnsetThreshold { get; init; }
    public bool IsOnset { get; init; }
    public double? Balance { get; init; }
    public double? SideEnergyRatio { get; init; }
    public double? Correlation { get; init; }
    public IReadOnlyList<double> DisplayBands { get; init; } = new double[24];
    public BeatFrame? Beat { get; init; }
}

public sealed record AudioFrame([property: JsonPropertyName("sessionID")] Guid SessionId, long Sequence, double ReceivedAt, AudioFeatures Audio, MelodyFrame? Melody)
{
    public int Version => 1;
}
public sealed record OnsetEvent(long Sequence, double Time, double ReceivedAt, double Strength);
public sealed record BeatEvent(long Sequence, double Time, double ReceivedAt, double Strength, double Bpm, double Confidence);
public sealed record AudioInput([property: JsonPropertyName("sessionID")] Guid SessionId, AudioState State, AudioFrame? Frame, double? FrameAge,
    IReadOnlyList<OnsetEvent> Onsets, IReadOnlyList<BeatEvent> Beats, double SpectralFluxPeak)
{
    public int Version => 1;
}
public sealed record AnalyzedAudio(AudioFeatures Audio, MelodyFrame? Melody, double ReceivedAt);
