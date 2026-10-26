using Miucs.Windows;

internal static class HoverLockTests
{
    public static void Run()
    {
        var state = new HoverLockState();
        Check(!state.Update(0, true, true), "initial hover");
        Sample(state, 0, 2.9);
        Check(!state.Update(2.999, true, true), "three second threshold");
        Check(state.Update(3, true, true), "show at threshold");
        for (int i = 0; i < 20; i++) Check(state.Update(3 + i * .05, true, true), "toggle must not reset dwell");
        Check(!state.Update(5, false, true), "leave hides");
        Check(!state.Update(6, true, true), "reentry restarts");
        Sample(state, 6, 8.9);
        Check(!state.Update(8.99, true, true), "reentry threshold");
        Check(state.Update(9, true, true), "reentry reveals");
        Check(!state.Update(10, true, false), "hide/suspend clears");
        Check(!state.Update(20, true, true), "resume starts fresh");
        Sample(state, 20, 22.9);
        Check(state.Update(23, true, true), "resume reveal");
        Check(!state.Update(24, true, true), "polling gap resets");
        Sample(state, 24, 26.9);
        Check(state.Update(27, true, true), "fresh dwell after stalled polling");
        state.Reset();
        Check(!state.IsVisible && !state.Update(28, true, true), "module change reset");
        Check(!state.Update(24, true, true), "clock rollback starts fresh");
        Check(!state.Update(double.NaN, true, true), "invalid time resets");
        Console.WriteLine("PASS: hover lock dwell, repeated state preservation, leave/reentry, lifecycle/stall reset");
    }
    private static void Sample(HoverLockState state, double start, double end)
    { for (double time = start + .1; time <= end + .00001; time += .1) state.Update(time, true, true); }
    private static void Check(bool result, string message) { if (!result) throw new Exception(message); }
}
