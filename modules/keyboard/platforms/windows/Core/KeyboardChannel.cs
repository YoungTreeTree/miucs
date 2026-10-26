using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
namespace Miucs.Keyboard;

public enum KeyboardState { Stopped, Connecting, Running, PermissionRequired, Suspended, SecureInput, Recovering }
[Flags] public enum KeyboardModifiers { None = 0, Shift = 1, Control = 2, Option = 4, Command = 8, CapsLock = 16, Fn = 32 }
public enum KeyboardEventKind { Pressed, Released, Repeated, ModifiersChanged }
public sealed record HeldKey(ushort KeyCode, double Duration);
public sealed record KeyboardEvent(long Sequence, double ReceivedAt, KeyboardEventKind Kind, ushort KeyCode,
    KeyboardModifiers Modifiers, double? HeldDuration = null, bool? ModifierIsPressed = null);
public sealed record KeyboardInput(Guid SessionId, long Sequence, KeyboardState State, double SampledAt,
    KeyboardModifiers Modifiers, IReadOnlyList<HeldKey> HeldKeys, double PressesPerSecond, double? IdleDuration,
    IReadOnlyList<KeyboardEvent> Events, long DroppedEventCount)
{
    public int Version => 1;
}

/// <summary>Ephemeral numeric physical-key channel; no text extraction or persistent history.</summary>
public sealed class KeyboardChannel
{
    private readonly object gate = new();
    private Guid session = Guid.NewGuid();
    private KeyboardState state;
    private long sequence;
    private KeyboardModifiers modifiers;
    private readonly Dictionary<ushort, double> held = new();
    private readonly Queue<KeyboardEvent> events = new();
    private readonly Queue<double> presses = new();
    private double? lastEvent;

    public Guid BeginSession(KeyboardState nextState)
    {
        lock (gate)
        {
            session = Guid.NewGuid(); state = nextState; sequence = 0; modifiers = KeyboardModifiers.None;
            held.Clear(); events.Clear(); presses.Clear(); lastEvent = null;
            return session;
        }
    }
    public void SetState(KeyboardState value) { lock (gate) state = value; }
    public KeyboardSubscription Subscribe() { lock (gate) return new(this, session, sequence); }
    public bool Publish(Guid generation, ushort code, bool down, KeyboardModifiers flags, double now, bool isModifier = false, bool? modifierIsPressed = null)
    {
        if (!double.IsFinite(now)) return false;
        lock (gate)
        {
            if (generation != session || state != KeyboardState.Running || (lastEvent.HasValue && now < lastEvent.Value)) return false;
            Expire(now);
            modifiers = flags;
            double? duration = held.TryGetValue(code, out double start) ? Math.Max(0, now - start) : null;
            KeyboardEventKind kind;
            if (isModifier) kind = KeyboardEventKind.ModifiersChanged;
            else if (down && duration.HasValue) kind = KeyboardEventKind.Repeated;
            else if (down)
            {
                kind = KeyboardEventKind.Pressed; held[code] = now; presses.Enqueue(now);
                while (presses.Count > 256) presses.Dequeue();
            }
            else { kind = KeyboardEventKind.Released; held.Remove(code); }
            events.Enqueue(new(++sequence, now, kind, code, modifiers, duration, isModifier ? modifierIsPressed : null));
            while (events.Count > 128) events.Dequeue();
            lastEvent = now; return true;
        }
    }
    private void Expire(double now)
    {
        while (events.TryPeek(out var e) && now - e.ReceivedAt > .25) events.Dequeue();
        while (presses.TryPeek(out var t) && now - t > 1) presses.Dequeue();
    }
    internal KeyboardInput Read(KeyboardSubscription subscription, double now)
    {
        if (!double.IsFinite(now)) throw new ArgumentOutOfRangeException(nameof(now));
        lock (gate)
        {
            Expire(now);
            if (subscription.Session != session) { subscription.Session = session; subscription.Cursor = 0; }
            var pending = events.Where(e => e.Sequence > subscription.Cursor).ToArray();
            long dropped = Math.Max(0, sequence - subscription.Cursor - pending.Length);
            subscription.Cursor = sequence;
            return new(session, sequence, state, now, modifiers,
                held.OrderBy(p => p.Key).Select(p => new HeldKey(p.Key, Math.Max(0, now - p.Value))).ToArray(),
                presses.Count, lastEvent.HasValue ? Math.Max(0, now - lastEvent.Value) : null, pending, dropped);
        }
    }
}
public sealed class KeyboardSubscription : IDisposable
{
    private readonly KeyboardChannel channel;
    internal Guid Session;
    internal long Cursor;
    private bool disposed;
    internal KeyboardSubscription(KeyboardChannel channel, Guid session, long cursor) { this.channel = channel; Session = session; Cursor = cursor; }
    public KeyboardInput Read(double now) { ObjectDisposedException.ThrowIf(disposed, this); return channel.Read(this, now); }
    public void Dispose() { disposed = true; }
}
