using System;

namespace Miucs.Windows;

/// <summary>Monotonic pointer dwell only; independent of lock state so toggles never flicker.</summary>
internal sealed class HoverLockState
{
    public const double DwellSeconds = 3;
    private double? enteredAt;
    private double? lastObservedAt;
    public bool IsVisible { get; private set; }

    public bool Update(double now, bool inside, bool available)
    {
        if (!available || !inside || !double.IsFinite(now)) { Reset(); return false; }
        if (lastObservedAt is double previous && (now < previous || now - previous > .5)) Reset();
        lastObservedAt = now;
        if (enteredAt == null) enteredAt = now;
        IsVisible = now - enteredAt.Value >= DwellSeconds;
        return IsVisible;
    }

    public void Reset() { enteredAt = null; lastObservedAt = null; IsVisible = false; }
}
