using System;
using System.Collections.Generic;

namespace Miucs.Visualizations;

public readonly record struct StaffTracePosition(double X, double Y);
public enum StaffTraceOperation { Move, Line, Curve }
public readonly record struct StaffTraceCommand(StaffTraceOperation Operation, StaffTracePosition End,
    StaffTracePosition Control1 = default, StaffTracePosition Control2 = default);

/// <summary>macOS tracePath/appendTraceJoin geometry, independent of WPF for regression replay.</summary>
public static class StaffTracePath
{
    public static IEnumerable<StaffTraceCommand> Build(StaffNoteScene scene)
    {
        int? segment = null;
        var previous = default(StaffTracePosition);
        TracePoint? liveTail = scene.HasContinuousTraceTail ? scene.Trace[^1] : null;
        double headOffset = liveTail is TracePoint tail ? scene.Y - tail.Y : 0;
        foreach (var point in scene.Trace)
        {
            double x = 640 - Math.Max(0, scene.Elapsed - point.Time) * 70, y = point.Y;
            if (point.Segment == liveTail?.Segment)
            {
                // Blend only the rendered last 10 units; accepted history stays fixed.
                double blend = Math.Clamp(1 - (640 - x) / 10, 0, 1);
                y += headOffset * Smooth(blend);
            }
            var end = new StaffTracePosition(x, y);
            if (segment != point.Segment)
                yield return new(StaffTraceOperation.Move, end);
            else if (point.JoinDuration > 0)
            {
                double progress = Smooth(Math.Clamp((scene.Elapsed - point.JoinedAt) / point.JoinDuration, 0, 1));
                foreach (var command in Join(previous, end, progress)) yield return command;
            }
            else yield return new(StaffTraceOperation.Line, end);
            segment = point.Segment;
            previous = end;
        }
        if (liveTail != null) yield return new(StaffTraceOperation.Line, new(640, scene.Y));
    }

    private static IEnumerable<StaffTraceCommand> Join(StaffTracePosition start, StaffTracePosition end, double progress)
    {
        double handle = (end.X - start.X) * .45;
        var c1 = new StaffTracePosition(start.X + handle, start.Y);
        var c2 = new StaffTracePosition(end.X - handle, end.Y);
        if (progress >= 1)
        {
            yield return new(StaffTraceOperation.Curve, end, c1, c2);
            yield break;
        }
        if (progress <= 0)
        {
            yield return new(StaffTraceOperation.Move, end);
            yield break;
        }
        // De Casteljau subdivision grows both tips along the final curve.
        double t = progress / 2, s = 1 - t;
        var left1 = Mix(start, c1, t);
        var left2 = Mix(left1, Mix(c1, c2, t), t);
        var leftEnd = Mix(left2, Mix(Mix(c1, c2, t), Mix(c2, end, t), t), t);
        yield return new(StaffTraceOperation.Curve, leftEnd, left1, left2);
        var right2 = Mix(c2, end, s);
        var right1 = Mix(Mix(c1, c2, s), right2, s);
        var rightStart = Mix(Mix(Mix(start, c1, s), Mix(c1, c2, s), s), right1, s);
        yield return new(StaffTraceOperation.Move, rightStart);
        yield return new(StaffTraceOperation.Curve, end, right1, right2);
    }

    private static double Smooth(double t) => t * t * (3 - 2 * t);
    private static StaffTracePosition Mix(StaffTracePosition a, StaffTracePosition b, double t) =>
        new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
}
