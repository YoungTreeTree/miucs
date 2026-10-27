using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace Miucs.Windows;

public sealed record WindowFrame(double X, double Y, double Width, double Height)
{
    public bool IsValid => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Width) && double.IsFinite(Height) && Width > 0 && Height > 0;
}

public static class WindowPlacement
{
    // All coordinates must use the same monitor-local logical coordinate space.
    public static WindowFrame Fit(WindowFrame requested, WindowFrame workArea, double aspect, double minWidth, double maxWidth)
    {
        if (!workArea.IsValid || !double.IsFinite(aspect) || aspect <= 0) throw new ArgumentException("Invalid display geometry");
        if (!requested.IsValid) requested = new(workArea.X + 24, workArea.Y + 24, minWidth, minWidth / aspect);
        double limit = Math.Min(maxWidth, Math.Min(workArea.Width, workArea.Height * aspect));
        double width = Math.Clamp(requested.Width, Math.Min(minWidth, limit), limit);
        double height = width / aspect;
        return new(Math.Clamp(requested.X, workArea.X, Math.Max(workArea.X, workArea.X + workArea.Width - width)),
            Math.Clamp(requested.Y, workArea.Y, Math.Max(workArea.Y, workArea.Y + workArea.Height - height)), width, height);
    }
}

public sealed class Preferences
{
    public string Visualization { get; set; } = "pencil-flight";
    public string Color { get; set; } = "graphite";
    private int transparency;
    public int Transparency { get => transparency; set => transparency = Math.Clamp(value, 0, 90); }
    public bool KeyboardEnabled { get; set; }
    public Dictionary<string, WindowFrame> Frames { get; set; } = new();
    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Miucs", "preferences.v1.json");
    public static Preferences Load(string path)
    {
        try
        {
            var result = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path));
            if (result == null) return new();
            result.Frames ??= new();
            result.Visualization = result.Visualization is "staff-note" or "pixel-keyboard" ? result.Visualization : "pencil-flight";
            result.Color = Palette.ContainsKey(result.Color ?? "") ? result.Color! : "graphite";
            foreach (var key in new List<string>(result.Frames.Keys))
                if (result.Frames[key] == null || !result.Frames[key].IsValid) result.Frames.Remove(key);
            return result;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { return new(); }
    }
    public bool Save(string path)
    {
        string temporary = path + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporary, path, true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { return false; }
    }
    public static readonly IReadOnlyDictionary<string, (string Name, byte R, byte G, byte B)> Palette =
        new Dictionary<string, (string, byte, byte, byte)>
        {
            ["graphite"] = ("石墨灰", 0x3D, 0x3D, 0x3D), ["mist-blue"] = ("雾蓝", 0x4F, 0x70, 0x87),
            ["moss-green"] = ("苔绿", 0x56, 0x70, 0x5B), ["ochre"] = ("赭橙", 0xBF, 0x70, 0x4B),
            ["mist-purple"] = ("雾紫", 0x8B, 0x72, 0xA2)
        };
}
