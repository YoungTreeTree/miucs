using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Diagnostics;
using System.Runtime.InteropServices;
using static Miucs.Audio.WasapiNative;

namespace Miucs.Audio;

/// <summary>Shared-mode WASAPI loopback of the default multimedia render endpoint. No microphone access.</summary>
public sealed class LoopbackCapture : IDisposable
{
    private readonly AudioChannel channel;
    private readonly object gate = new();
    private readonly object stateGate = new();
    private long activeLifetime;
    private CancellationTokenSource? cancellation;
    private Thread? worker;
    private bool enabled, suspended, disposed;
    /// <summary>Non-sensitive diagnostic category only; never includes device names, audio or paths.</summary>
    public string? LastError { get; private set; }
    public LoopbackCapture(AudioChannel channel) { this.channel = channel; }
    public void Start() { lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); enabled = true; StartWorker(); } }
    public void Stop() { lock (gate) { enabled = false; StopWorker(AudioState.UserStopped); } }
    public void Reconnect() { lock (gate) { if (disposed) return; StopWorker(AudioState.Recovering); if (enabled) StartWorker(); } }
    public void Suspend() { lock (gate) { suspended = true; StopWorker(AudioState.Suspended); } }
    public void Resume() { lock (gate) { suspended = false; if (enabled && !disposed) StartWorker(); } }
    private void StartWorker()
    {
        if (!enabled || suspended || worker != null) return;
        cancellation = new();
        var source = cancellation;
        long lifetime;
        lock (stateGate) lifetime = ++activeLifetime;
        worker = new Thread(() => { try { Run(source.Token, lifetime); } finally { source.Dispose(); } }) { IsBackground = true, Name = "Miucs WASAPI loopback" };
        worker.SetApartmentState(ApartmentState.MTA);
        worker.Start();
    }
    private void StopWorker(AudioState state)
    {
        try { cancellation?.Cancel(); } catch (ObjectDisposedException) { }
        // Retire the generation immediately. A stalled driver must not freeze the UI indefinitely.
        lock (stateGate) { activeLifetime++; channel.BeginSession(state); }
        worker?.Join(250); worker = null; cancellation = null;
        // A late worker owns its COM cleanup and CTS. All state writes are lifetime-guarded,
        // and its old generation cannot publish into the replacement capture.
    }
    private void Run(CancellationToken token, long lifetime)
    {
        int initialized = CoInitializeEx(0, 0);
        if (initialized < 0) { SetStatus(lifetime, AudioState.Recovering, "COM initialization failed"); return; }
        try
        {
            int attempt = 0;
            while (!token.IsCancellationRequested)
            {
                Guid generation = BeginSession(lifetime, attempt == 0 ? AudioState.Connecting : AudioState.Recovering);
                double began = Now;
                try { Capture(generation, token, lifetime); attempt = 0; }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
                catch (Exception ex) when (ex is COMException or NotSupportedException or InvalidOperationException or ArgumentException)
                {
                    if (token.IsCancellationRequested) break;
                    SetStatus(lifetime, null, ex is NotSupportedException ? ex.Message : "Audio device unavailable; retrying");
                    BeginSession(lifetime, ex.HResult == unchecked((int)0x80070005) ? AudioState.PermissionRequired : AudioState.Recovering);
                    if (Now - began > 5) attempt = 0;
                    double delay = Math.Min(30, Math.Pow(2, Math.Min(attempt++, 5)));
                    token.WaitHandle.WaitOne(TimeSpan.FromSeconds(delay));
                }
            }
        }
        finally { CoUninitialize(); }
    }
    private void Capture(Guid generation, CancellationToken token, long lifetime)
    {
        IMMDeviceEnumerator? enumerator = null; IMMDevice? device = null;
        IAudioClient? client = null; IAudioCaptureClient? capture = null;
        nint formatPointer = 0;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            Check(enumerator.GetDefaultAudioEndpoint(0, 1, out device)); // eRender, eMultimedia
            Check(device.GetId(out var endpointId));
            Check(device.Activate(AudioClientId, 23, 0, out var audioObject));
            client = (IAudioClient)audioObject;
            Check(client.GetMixFormat(out formatPointer));
            int formatLength = 18 + (ushort)Marshal.ReadInt16(formatPointer, 16);
            if (formatLength > 4096) throw new NotSupportedException("Invalid playback format.");
            byte[] formatBytes = new byte[formatLength]; Marshal.Copy(formatPointer, formatBytes, 0, formatLength);
            var format = PcmFormat.Parse(formatBytes);
            Check(client.Initialize(0, Loopback, 1_000_000, 0, formatPointer, 0));
            Check(client.GetService(CaptureClientId, out var captureObject)); capture = (IAudioCaptureClient)captureObject;
            var analyzer = new AudioAnalyzer();
            Check(client.Start());
            token.ThrowIfCancellationRequested();
            SetStatus(lifetime, AudioState.Running, null);
            double nextDeviceCheck = Now + 1;
            while (!token.IsCancellationRequested)
            {
                Check(capture.GetNextPacketSize(out uint packetFrames));
                while (packetFrames > 0 && !token.IsCancellationRequested)
                {
                    Check(capture.GetBuffer(out var data, out uint frames, out uint flags, out _, out _));
                    try
                    {
                        if ((flags & 1) != 0) // AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY
                        {
                            analyzer.Reset();
                            generation = BeginSession(lifetime, AudioState.Running);
                        }
                        bool silent = (flags & Silent) != 0;
                        int count = checked((int)frames);
                        byte[] bytes = silent ? Array.Empty<byte>() : new byte[checked(count * format.BlockAlign)];
                        if (!silent) Marshal.Copy(data, bytes, 0, bytes.Length);
                        double received = Now;
                        float[] pcm = format.Decode(bytes, count, silent);
                        foreach (var analyzed in analyzer.Process(pcm, format.SampleRate, format.Channels, received))
                            channel.Publish(generation, analyzed.Audio, analyzed.Melody, analyzed.ReceivedAt);
                    }
                    finally { Check(capture.ReleaseBuffer(frames)); }
                    Check(capture.GetNextPacketSize(out packetFrames));
                }
                if (Now >= nextDeviceCheck)
                {
                    IMMDevice? current = null;
                    try
                    {
                        Check(enumerator.GetDefaultAudioEndpoint(0, 1, out current));
                        Check(current.GetId(out var currentId));
                        if (currentId != endpointId) return; // Reopen with a fresh generation and format.
                        Check(device.GetState(out uint state));
                        if (state != 1) return;
                    }
                    finally { Release(current); }
                    nextDeviceCheck = Now + 1;
                }
                // An idle output endpoint may deliver no packets. Do not fabricate PCM or reconnect on silence.
                token.WaitHandle.WaitOne(8);
            }
        }
        finally
        {
            if (client != null) client.Stop();
            if (formatPointer != 0) Marshal.FreeCoTaskMem(formatPointer);
            Release(capture); Release(client); Release(device); Release(enumerator);
        }
    }
    private Guid BeginSession(long lifetime, AudioState state)
    {
        lock (stateGate) return lifetime == activeLifetime ? channel.BeginSession(state) : Guid.Empty;
    }
    private void SetStatus(long lifetime, AudioState? state, string? error)
    {
        lock (stateGate)
        {
            if (lifetime != activeLifetime) return;
            if (state.HasValue) channel.SetState(state.Value);
            LastError = error;
        }
    }
    private static double Now => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    public void Dispose() { lock (gate) { if (disposed) return; enabled = false; StopWorker(AudioState.Stopped); disposed = true; } }
}
