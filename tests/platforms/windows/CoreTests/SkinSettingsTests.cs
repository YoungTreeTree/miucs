using System;
using System.IO;
using System.Linq;
using Miucs.Windows;

public static class SkinSettingsTests
{
    public static void Run()
    {
        static void Check(bool value, string message) { if (!value) throw new InvalidOperationException("Skin settings: " + message); }
        string directory = Path.Combine(Path.GetTempPath(), "miucs-skins-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "prefs.json");
            var original = new WindowFrame(-450, 120, 261, 151);
            var prefs = new Preferences { Visualization = "skin-a" };
            prefs.Frames["skin-a"] = original; prefs.Frames["skin-b"] = new(700, 500, 800, 800);
            Check(prefs.RestoreSkinFrame("skin-a", new(80, 80, 800, 460)) == original, "upgrade restores exact current skin rectangle");
            prefs.SkinFrame = prefs.RestoreSkinFrame("skin-a", new(80, 80, 800, 460));
            for (int i = 0; i < 150; i++)
            {
                prefs.Visualization = i % 2 == 0 ? "skin-b" : "skin-a";
                Check(prefs.RestoreSkinFrame(prefs.Visualization, new(80, 80, 800, 800)) == original, "switch ignores old per-skin frame and different aspect ratio");
            }
            Check(prefs.Save(path), "shared frame saves");
            var restored = Preferences.Load(path);
            Check(restored.SkinFrame == original, "restart keeps rounded saved height");
            Check(restored.Frames["skin-b"] == new WindowFrame(700, 500, 800, 800), "legacy records untouched");
            var area = new WindowFrame(-600, 0, 1200, 900);
            Check(WindowPlacement.FitPreservingSize(original, area) == original, "visible shared frame does not change");
            var fitted = WindowPlacement.FitPreservingSize(new(2000, -800, 1000, 2000), area);
            Check(fitted.Width == 450 && fitted.Height == 900 && fitted.X + fitted.Width <= 600 && fitted.Y == 0, "screen removal fits original aspect, independent of next skin");
            foreach (string retired in new[] { "pencil-flight", "staff-note" })
            {
                File.WriteAllText(path, "{\"Visualization\":\"" + retired + "\",\"SkinFrame\":{\"X\":0,\"Y\":0,\"Width\":0,\"Height\":10}}");
                Check(Preferences.Load(path).Visualization == "pixel-keyboard" && Preferences.Load(path).SkinFrame == null, "retired selection and corrupt shared geometry recover");
            }
            File.WriteAllBytes(Path.Combine(directory, "preview.png"), new byte[] { 1, 2, 3 });
            File.WriteAllBytes(Path.Combine(directory, "preview.gif"), new byte[] { 1, 2, 3 });
            Check(SkinCatalog.PreviewCandidates(directory).Select(Path.GetExtension).SequenceEqual(new[] { ".gif", ".png" }), "preview precedence is deterministic");
            using (var oversized = File.Create(Path.Combine(directory, "preview.jpg"))) oversized.SetLength(SkinCatalog.MaximumPreviewBytes + 1);
            Check(SkinCatalog.PreviewCandidates(directory).Count() == 2, "oversized artwork is ignored");
            Check(!SkinCatalog.IsRetired("heiji-kazuha") && SkinCatalog.IsRetired("staff-note"), "supported skins remain available");
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine("PASS skin settings: 150 switches, migration/restart, monitor fitting, retired skins and bounded previews");
    }
}
