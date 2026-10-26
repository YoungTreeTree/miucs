using System;
using System.IO;
using Miucs.Windows;

public static class ShellTests
{
    private static int assertions;
    private static void Check(bool condition, string message)
    {
        assertions++;
        if (!condition) throw new InvalidOperationException("Shell: " + message);
    }
    private static bool Near(double a, double b) => Math.Abs(a - b) < 1e-8;
    private static void Contained(WindowFrame frame, WindowFrame area, double aspect)
    {
        Check(frame.IsValid, "placement finite and positive");
        Check(frame.X >= area.X && frame.Y >= area.Y, "placement within top/left work area");
        Check(frame.X + frame.Width <= area.X + area.Width + 1e-8 && frame.Y + frame.Height <= area.Y + area.Height + 1e-8, "placement within bottom/right work area");
        Check(Near(frame.Width / frame.Height, aspect), "module aspect preserved");
    }
    public static void Run()
    {
        var monitor = new WindowFrame(0, 0, 1920, 1040);
        var flight = WindowPlacement.Fit(new(80, 80, 400, 260), monitor, 400d / 260, 280, 1000);
        Check(flight == new WindowFrame(80, 80, 400, 260), "valid flight placement unchanged");
        var staff = WindowPlacement.Fit(new(-9000, 9000, 1600, 320), monitor, 5, 600, 1600);
        Contained(staff, monitor, 5);
        Check(Near(staff.X, 0) && Near(staff.Y, 720), "off-screen saved placement restored");
        var small = new WindowFrame(0, 0, 420, 90);
        var scaled = WindowPlacement.Fit(new(12, 12, 800, 160), small, 5, 600, 1600);
        Contained(scaled, small, 5);
        Check(Near(scaled.Width, 420), "small display overrides module minimum instead of clipping");
        var leftDisplay = new WindowFrame(-1920, -120, 1920, 1040);
        var left = WindowPlacement.Fit(new(-1800, -80, 800, 160), leftDisplay, 5, 600, 1600);
        Check(Near(left.X, -1800) && Near(left.Y, -80), "negative monitor coordinates are not mistaken for invalid values");
        Contained(left, leftDisplay, 5);
        var invalid = WindowPlacement.Fit(new(double.NaN, 0, double.PositiveInfinity, 0), monitor, 5, 600, 1600);
        Contained(invalid, monitor, 5);
        Check(Near(invalid.Width, 600), "corrupt saved geometry falls back to a finite module size");
        bool rejected = false;
        try { WindowPlacement.Fit(flight, new(0, 0, 0, 10), 5, 600, 1600); }
        catch (ArgumentException) { rejected = true; }
        Check(rejected, "invalid work area rejected");
        var random = new Random(1977);
        for (int i = 0; i < 500; i++)
        {
            var area = new WindowFrame(random.Next(-4000, 4000), random.Next(-1000, 1000), random.Next(80, 4000), random.Next(60, 2200));
            double aspect = i % 2 == 0 ? 5 : 400d / 260;
            var request = new WindowFrame(random.Next(-9000, 9000), random.Next(-6000, 6000), random.Next(1, 5000), random.Next(1, 5000));
            Contained(WindowPlacement.Fit(request, area, aspect, 280, 1600), area, aspect);
        }

        string directory = Path.Combine(Path.GetTempPath(), "miucs-shell-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "preferences.json");
        try
        {
            var defaults = Preferences.Load(path);
            Check(!defaults.KeyboardEnabled, "keyboard capture is opt-in on first launch");
            Check(defaults.Visualization == "pencil-flight" && defaults.Color == "graphite", "stable first-launch defaults");
            Check(Preferences.Palette.Count == 5, "five shared colors");
            defaults.Visualization = "staff-note"; defaults.Color = "mist-blue"; defaults.KeyboardEnabled = true;
            defaults.Frames["staff-note"] = new(-100, 70, 1000, 200);
            defaults.Frames["pencil-flight"] = new(100, 200, 500, 325);
            Check(defaults.Save(path), "preferences atomic save succeeds");
            Check(!File.Exists(path + ".tmp"), "no temporary preference file remains after save");
            var loaded = Preferences.Load(path);
            Check(loaded.Visualization == "staff-note" && loaded.Color == "mist-blue" && loaded.KeyboardEnabled, "global selection and explicit keyboard preference round-trip");
            Check(loaded.Frames.Count == 2 && loaded.Frames["staff-note"] == defaults.Frames["staff-note"] && loaded.Frames["pencil-flight"] == defaults.Frames["pencil-flight"], "module positions/sizes remain independent");
            File.WriteAllText(path, "{ not json");
            Check(Preferences.Load(path).Visualization == "pencil-flight", "truncated JSON recovers to defaults");
            File.WriteAllText(path, "null");
            Check(!Preferences.Load(path).KeyboardEnabled, "null JSON recovers with keyboard disabled");
            File.WriteAllText(path, "{\"Visualization\":\"unknown\",\"Color\":null,\"Frames\":null}");
            var unknown = Preferences.Load(path);
            Check(unknown.Visualization == "pencil-flight" && unknown.Color == "graphite" && unknown.Frames.Count == 0, "unknown IDs and null collections sanitized");
            File.WriteAllText(path, "{\"Frames\":{\"staff-note\":{\"X\":0,\"Y\":0,\"Width\":0,\"Height\":1},\"pencil-flight\":null}}");
            Check(Preferences.Load(path).Frames.Count == 0, "invalid individual saved frames removed");
            Check(!loaded.Save(directory), "unwritable file target is a recoverable save failure");
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine($"ShellTests: {assertions} assertions passed (portable geometry/preferences only; not native DPI/window validation).");
    }
}
