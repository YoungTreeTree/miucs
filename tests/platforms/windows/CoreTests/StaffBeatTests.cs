using System;
using System.Linq;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;

public static class StaffBeatTests
{
    private static int assertions;
    private static void Check(bool value, string message)
    { assertions++; if (!value) throw new InvalidOperationException("Staff beats: " + message); }
    private static BeatEvent Beat(long sequence, double time) => new(sequence, time, time, 1, 120, .9);
    public static void Run()
    {
        var scene = new StaffBeatRings(0x42454154);
        scene.Advance(0, new[] { Beat(1, 0) }, 0, 1);
        var birth = scene.Rings[0];
        Check(scene.Rings.Count == 1 && birth.Opacity == 0 && birth.Radius == 4, "birth starts with a soft outer wave");
        scene.Advance(.1, new[] { Beat(1, 0) }, .1, 1);
        Check(scene.TotalPulses == 1 && scene.Rings.Count == 3, "90ms inner wave and 100ms satellite without event replay");
        Check(scene.Rings[0].X == birth.X && scene.Rings[0].Y == birth.Y, "main center remains fixed");
        scene.Advance(.2, Array.Empty<BeatEvent>(), .3, 1);
        // Produced by unmodified core/StaffBeatRings.swift at seed 0x42454154, t=0.3, strength=1.
        double[][] mac = {
            new[] {327.30720781531863,81.80625986242845,25.1640625,.4353022171687066,1.05,2.716404045989475},
            new[] {327.30720781531863,81.80625986242845,15.9773828125,.3433835328516758,.72,2.9164040459894753},
            new[] {309.75857857079797,66.85387265958195,4.878203288367708,.331123049563681,.65,3.9584893002462125},
            new[] {356.2575593509007,76.51285078430294,5.43125,.38943609840914706,.65,6.058489300246213},
            new[] {319.0581946989903,107.17329648067573,3.008668867112222,.44924618033096186,.65,8.108489300246212}
        };
        Check(scene.Rings.Count == mac.Length, "two main waves and three satellites match macOS");
        for (int i = 0; i < mac.Length; i++)
        {
            var ring = scene.Rings[i];
            var values = new[] { ring.X, ring.Y, ring.Radius, ring.Opacity, ring.LineWidth, ring.Rotation };
            Check(values.Zip(mac[i], (a, b) => Math.Abs(a - b) < 1e-10).All(x => x) &&
                ring.Arc == (i < 2 ? StaffBeatArc.Main : StaffBeatArc.Satellite), "native Swift numeric reference " + i);
        }
        scene.Advance(.52, Array.Empty<BeatEvent>(), .82, 1);
        Check(scene.Rings.Count == 1 && scene.Rings[0].Opacity < .1, "delayed inner arc finishes last");
        scene.Advance(.08, Array.Empty<BeatEvent>(), .9, 1);
        Check(scene.Rings.Count == 0, "all waves expire within 890ms");
        scene.Advance(0, new[] { Beat(2, .5), Beat(3, 1), Beat(4, .9) with { Confidence = .2 },
            Beat(5, .9) with { Strength = double.NaN }, Beat(6, .9) with { Bpm = 201 }, Beat(9, .9) }, .9, 6);
        Check(scene.TotalPulses == 1 && scene.Rings.Count == 0, "stale, future, invalid and beyond-cursor beats are ignored");
        scene.Clear(10); scene.Advance(0, new[] { Beat(10, 1) }, 1, 10);
        Check(scene.Rings.Count == 0, "clearing through a cursor prevents replay");
        scene.Advance(.1, Enumerable.Range(11, 16).Select(i => Beat(i, 1.1)).ToArray(), 1.1, 26);
        scene.Advance(.25, Array.Empty<BeatEvent>(), 1.35, 26);
        Check(scene.Rings.Count == StaffBeatRings.Limit, "burst backlog is bounded to four pulses / twenty arcs");
        scene.Advance(4, Array.Empty<BeatEvent>(), 5.35, 26);
        Check(scene.Rings.Count == 0, "long stall expires history without replaying");

        var scattered = new StaffBeatRings(0x42454154); double minX = 800, maxX = 0, minY = 160, maxY = 0;
        double? previous = null;
        for (int i = 1; i <= 48; i++)
        {
            scattered.Advance(.5, new[] { Beat(i, i * .5) }, i * .5, i);
            var origin = scattered.Rings[^1];
            Check(origin.X is >= 112 and <= 712 && origin.Y is >= 48 and <= 112, "origin stays in the macOS region");
            Check(previous == null || Math.Abs(origin.X - previous.Value) >= 120, "successive beats remain separated");
            previous = origin.X; minX = Math.Min(minX, origin.X); maxX = Math.Max(maxX, origin.X);
            minY = Math.Min(minY, origin.Y); maxY = Math.Max(maxY, origin.Y);
        }
        Check(maxX - minX > 480 && maxY - minY > 45, "origins cover the expanded macOS region");
        VerifyLifecycle();
        Console.WriteLine($"Staff beats: {assertions} assertions passed (including unmodified Swift reference).");
    }
    private static void VerifyLifecycle()
    {
        var scene = new StaffNoteScene(); var session = Guid.NewGuid();
        var keys = new KeyboardInput(Guid.NewGuid(), 0, KeyboardState.Running, 0, KeyboardModifiers.None,
            Array.Empty<HeldKey>(), 0, null, Array.Empty<KeyboardEvent>(), 0);
        AudioInput Input(long sequence, double rate = 48000, bool silent = false) =>
            new(session, AudioState.Running, new AudioFrame(session, sequence, sequence * .02,
                new AudioFeatures { Time = sequence * .02, SampleRate = rate, ChannelCount = 2, IsSilent = silent }, null),
                0, Array.Empty<OnsetEvent>(), new[] { Beat(sequence, sequence * .02) }, 0);
        scene.Update(Input(1), keys, .02);
        Check(scene.Rings.Count == 1 && scene.Pitch == null, "percussion without melody still produces a wave");
        scene.Update(Input(2, rate: 44100), keys, .02);
        Check(scene.Rings.Count == 0, "format change discards old waves and queued beat events");
        scene.Update(Input(3, rate: 44100), keys, .02);
        Check(scene.Rings.Count == 1, "fresh beat after format change resumes");
        scene.Update(Input(4, rate: 44100, silent: true), keys, .02);
        Check(scene.Rings.Count == 0, "silence clears waves");
        scene.Update(Input(5, rate: 44100) with { FrameAge = .5 }, keys, .02);
        Check(scene.Rings.Count == 0, "stale capture cannot trigger waves");
        scene.Update(Input(6, rate: 44100), keys, .02); scene.Reset();
        Check(scene.Rings.Count == 0 && scene.BeatRings.TotalPulses == 0, "hide/reset clears wave state");
    }
}
