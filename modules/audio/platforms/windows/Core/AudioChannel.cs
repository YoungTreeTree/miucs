using System;
using System.Collections.Generic;
using System.Linq;

namespace Miucs.Audio;

/// <summary>A short lock protects only bounded data, never callbacks or UI work.</summary>
public sealed class AudioChannel
{
    private readonly object gate = new();
    private Guid session = Guid.NewGuid();
    private long sequence;
    private AudioState state;
    private AudioFrame? frame;
    private readonly List<OnsetEvent> onsets = new();
    private readonly List<BeatEvent> beats = new();
    private readonly LinkedList<(long Sequence, double ReceivedAt, double Value)> peaks = new();
    private double latestReceived = double.NegativeInfinity;
    private double lastBeatTime = double.NegativeInfinity;

    public Guid BeginSession(AudioState newState)
    {
        lock (gate)
        {
            session = Guid.NewGuid(); sequence = 0; state = newState; frame = null;
            onsets.Clear(); beats.Clear(); peaks.Clear(); latestReceived = lastBeatTime = double.NegativeInfinity;
            return session;
        }
    }
    public void SetState(AudioState newState)
    {
        lock (gate)
        {
            state = newState;
            if (state != AudioState.Running) { onsets.Clear(); beats.Clear(); peaks.Clear(); }
        }
    }
    // A capture generation can only change its own state, avoiding late callback races.
    public bool SetState(Guid expectedSession, AudioState newState)
    {
        lock (gate)
        {
            if (expectedSession != session) return false;
            SetState(newState); return true;
        }
    }
    public bool Publish(Guid expectedSession, AudioFeatures audio, MelodyFrame? melody, double receivedAt)
    {
        if (!double.IsFinite(receivedAt)) throw new ArgumentOutOfRangeException(nameof(receivedAt));
        lock (gate)
        {
            if (expectedSession != session || state != AudioState.Running || receivedAt < latestReceived) return false;
            bool changed = frame != null && (frame.Audio.SampleRate != audio.SampleRate ||
                frame.Audio.ChannelCount != audio.ChannelCount || audio.Time < frame.Audio.Time);
            if (changed) { onsets.Clear(); beats.Clear(); peaks.Clear(); lastBeatTime = double.NegativeInfinity; }
            // A quiet latest snapshot must not erase a short unread transient.
            // Beat pulses, unlike onset/flux history, stop immediately in silence.
            if (audio.IsSilent) beats.Clear();
            latestReceived = receivedAt;
            frame = new AudioFrame(session, ++sequence, receivedAt, audio, melody);
            Prune(receivedAt);
            if (!audio.IsSilent)
            {
                if (audio.IsOnset) onsets.Add(new OnsetEvent(sequence, audio.Time, receivedAt, audio.SpectralFlux));
                if (audio.Beat is { BeatTime: not null, Bpm: not null } b &&
                    double.IsFinite(b.BeatTime.Value) && b.BeatTime >= 0 && b.BeatTime <= audio.Time &&
                    audio.Time - b.BeatTime <= .100000001 && b.BeatTime > lastBeatTime &&
                    b.Bpm >= 50 && b.Bpm <= 200 && b.Confidence >= .45 && b.Confidence <= 1 &&
                    b.Strength >= 0 && b.Strength <= 1)
                {
                    beats.Add(new BeatEvent(sequence, b.BeatTime.Value,
                        receivedAt - Math.Max(0, audio.Time - b.BeatTime.Value), b.Strength, b.Bpm.Value, b.Confidence));
                    lastBeatTime = b.BeatTime.Value;
                }
                if (double.IsFinite(audio.SpectralFlux) && audio.SpectralFlux > 0)
                {
                    while (peaks.Last != null && peaks.Last.Value.Value <= audio.SpectralFlux) peaks.RemoveLast();
                    peaks.AddLast((sequence, receivedAt, audio.SpectralFlux));
                }
            }
            if (onsets.Count > 64) onsets.RemoveRange(0, onsets.Count - 64);
            if (beats.Count > 64) beats.RemoveRange(0, beats.Count - 64);
            // Peaks are bounded by the 250 ms lifetime, not the 64-event capacity.
            // Truncating a descending burst here would lose its unread maximum.
            return true;
        }
    }
    private void Prune(double now)
    {
        onsets.RemoveAll(e => now - e.ReceivedAt > .25);
        beats.RemoveAll(e => now - e.ReceivedAt > .25);
        while (peaks.First != null && now - peaks.First.Value.ReceivedAt > .25) peaks.RemoveFirst();
    }
    public AudioSubscription Subscribe()
    {
        lock (gate) return new AudioSubscription(this, session, sequence);
    }
    internal AudioInput Read(AudioSubscription reader, double now)
    {
        if (!double.IsFinite(now)) throw new ArgumentOutOfRangeException(nameof(now));
        lock (gate)
        {
            Prune(now);
            if (reader.Session != session) { reader.Session = session; reader.Cursor = 0; }
            var unreadOnsets = onsets.Where(e => e.Sequence > reader.Cursor).ToArray();
            var unreadBeats = beats.Where(e => e.Sequence > reader.Cursor).ToArray();
            double peak = 0;
            foreach (var p in peaks) if (p.Sequence > reader.Cursor) peak = Math.Max(peak, p.Value);
            reader.Cursor = sequence;
            return new AudioInput(session, state, frame, frame == null ? null : Math.Max(0, now - frame.ReceivedAt),
                unreadOnsets, unreadBeats, peak);
        }
    }
}

public sealed class AudioSubscription : IDisposable
{
    private readonly AudioChannel channel;
    private bool disposed;
    internal Guid Session;
    internal long Cursor;
    internal AudioSubscription(AudioChannel channel, Guid session, long cursor)
    { this.channel = channel; Session = session; Cursor = cursor; }
    public AudioInput Read(double now)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return channel.Read(this, now);
    }
    public void Dispose() => disposed = true;
}
