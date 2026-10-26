using Miucs.Keyboard;

internal static class KeyboardTests
{
    public static void Run()
    {
        int count = 0;
        void Check(bool value, string message) { if (!value) throw new Exception(message); count++; }
        var c = new KeyboardChannel();
        var gen = c.BeginSession(KeyboardState.Running);
        var a = c.Subscribe(); var b = c.Subscribe();
        Check(c.Publish(gen, 0x1E, true, 0, 10), "publish accepted");
        Check(!c.Publish(gen, 0x1E, false, 0, 9), "regressing callback rejected");
        bool badTime = false; try { a.Read(double.NaN); } catch (ArgumentOutOfRangeException) { badTime = true; }
        Check(badTime, "nonfinite read clock rejected");
        var input = a.Read(10.1);
        Check(input.Events.Count == 1 && input.Events[0].Kind == KeyboardEventKind.Pressed, "press event");
        Check(input.HeldKeys.Count == 1 && Math.Abs(input.HeldKeys[0].Duration - .1) < 1e-8, "held duration");
        Check(b.Read(10.1).Events.Count == 1 && a.Read(10.1).Events.Count == 0, "independent cursors");
        Check(c.Subscribe().Read(10.1).Events.Count == 0, "new subscriber no replay");
        c.Publish(gen, 0x1E, true, 0, 10.12);
        Check(a.Read(10.13).Events.Single().Kind == KeyboardEventKind.Repeated, "OS repeat classified");
        Check(a.Read(10.13).PressesPerSecond == 1, "OS repeat not frequency");
        c.Publish(gen, 0x1E, false, 0, 10.2);
        input = a.Read(10.21);
        Check(input.HeldKeys.Count == 0 && input.Events[0].HeldDuration > .19, "release lifecycle");
        c.Publish(gen, 0x2A, true, KeyboardModifiers.Shift, 10.22, true, true);
        input = a.Read(10.23);
        Check(input.HeldKeys.Count == 0 && input.Events[0].ModifierIsPressed == true, "modifier excluded from holds");
        Check(input.PressesPerSecond == 1 && input.Modifiers == KeyboardModifiers.Shift, "modifier frequency excluded");
        Check(a.Read(11.3).PressesPerSecond == 0, "idle frequency expires");
        for (int i = 0; i < 150; i++) c.Publish(gen, (ushort)(i + 1), true, 0, 12 + i * .0001);
        input = a.Read(12.02);
        Check(input.Events.Count == 128 && input.DroppedEventCount == 22, "bounded event overflow");
        Check(a.Read(12.03).DroppedEventCount == 0, "drops once only");
        c.Publish(gen, 200, true, 0, 12.1);
        input = a.Read(12.36);
        Check(input.Events.Count == 0 && input.DroppedEventCount == 1, "expiry counted");
        Check(input.HeldKeys.Count > 0, "event expiry retains held keys");
        var next = c.BeginSession(KeyboardState.Suspended);
        Check(!c.Publish(gen, 1, true, 0, 13), "late generation rejected");
        input = a.Read(13);
        Check(input.SessionId == next && input.HeldKeys.Count == 0 && input.Events.Count == 0 && input.Modifiers == 0, "generation clears all input");
        Check(!c.Publish(next, 1, true, 0, 13), "suspended rejects input");
        c.BeginSession(KeyboardState.Running);
        a.Dispose(); bool threw = false; try { a.Read(14); } catch (ObjectDisposedException) { threw = true; }
        Check(threw, "subscription disposal");
        Console.WriteLine($"Keyboard tests: {count} assertions passed.");
    }
}
