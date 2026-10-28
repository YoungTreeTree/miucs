using System;
using System.IO;
using System.Linq;
using Miucs.Windows;
using Miucs.Visualizations;
using Miucs.Keyboard;

public static class TrayIconTests
{
    private static int assertions;
    private static void Check(bool result, string message)
    { assertions++; if (!result) throw new InvalidOperationException("Tray icon: " + message); }

    public static void Run()
    {
        Check(TrayIconPose.FromAngle(0) == TrayIconPose.RestFrame, "rest pose is upright");
        Check(TrayIconPose.FromAngle(double.NaN) == TrayIconPose.RestFrame, "invalid angle is safe");
        Check(TrayIconPose.FromAngle(100) == 24 && TrayIconPose.FromAngle(-100) == 0, "pose range is bounded");
        var head = new PixelHeadScene(); var session = Guid.NewGuid(); long sequence = 0;
        bool sawLeft = false, sawRight = false;
        for (int i = 0; i < 600; i++)
        {
            double time = i / 60d;
            bool pressed = i < 300 && i % 10 == 0;
            var events = pressed ? new[] { new KeyboardEvent(++sequence, time, KeyboardEventKind.Pressed, 30, KeyboardModifiers.None) } : Array.Empty<KeyboardEvent>();
            head.Update(new KeyboardInput(session, sequence, KeyboardState.Running, time, KeyboardModifiers.None,
                Array.Empty<HeldKey>(), i < 300 ? 6 : 0, 0, events, 0), 1d / 60);
            int pose = TrayIconPose.FromAngle(head.Angle);
            Check(Math.Abs(TrayIconPose.Angle(pose) - head.Angle) <= Math.PI / 360 + 1e-9,
                "cached tray pose follows floating head within half a degree");
            sawLeft |= pose < TrayIconPose.RestFrame; sawRight |= pose > TrayIconPose.RestFrame;
        }
        Check(sawLeft && sawRight && TrayIconPose.FromAngle(head.Angle) == TrayIconPose.RestFrame,
            "typing moves both directions and idle settles to rest");

        var source = new byte[32 * 32 * 4];
        for (int y = 4; y < 29; y++) for (int x = 5; x < 27; x++)
        { int at = (y * 32 + x) * 4; source[at] = (byte)(x * 7); source[at + 1] = (byte)(y * 7); source[at + 2] = 40; source[at + 3] = 255; }
        var original = (byte[])source.Clone();
        byte[] left = TrayIconArtwork.Render(source, 32, 32, 0, 32), right = TrayIconArtwork.Render(source, 32, 32, 24, 32);
        Check(!left.SequenceEqual(right), "opposite poses produce different pixels");
        Check(source.SequenceEqual(original), "artwork never modifies the bundled portrait");
        foreach (int frame in new[] { 0, 12, 24 })
        {
            var encoded = TrayIconArtwork.EncodeIcon(source, 32, 32, frame);
            using var stream = new MemoryStream(encoded); using var reader = new BinaryReader(stream);
            Check(reader.ReadUInt16() == 0 && reader.ReadUInt16() == 1 && reader.ReadUInt16() == 7, "multi-resolution ICO header");
            int previousEnd = 6 + 7 * 16;
            for (int entry = 0; entry < 7; entry++)
            {
                stream.Position = 6 + entry * 16;
                int size = reader.ReadByte(); Check(reader.ReadByte() == size, "square icon directory entry");
                reader.ReadUInt16(); Check(reader.ReadUInt16() == 1 && reader.ReadUInt16() == 32, "RGBA icon depth");
                int length = reader.ReadInt32(), offset = reader.ReadInt32();
                Check(offset == previousEnd && offset + length <= encoded.Length, "icon payloads are bounded and contiguous");
                previousEnd = offset + length; stream.Position = offset;
                Check(reader.ReadInt32() == 40 && reader.ReadInt32() == size && reader.ReadInt32() == 2 * size, "DIB includes color and transparency planes");
                var pixels = TrayIconArtwork.Render(source, 32, 32, frame, size);
                int visible = 0, transparent = 0, maskStride = (size + 31) / 32 * 4;
                for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
                {
                    int sourceAt = (y * size + x) * 4, storedAt = offset + 40 + ((size - 1 - y) * size + x) * 4;
                    Check(encoded[storedAt] == pixels[sourceAt + 2] && encoded[storedAt + 2] == pixels[sourceAt] &&
                        encoded[storedAt + 3] == pixels[sourceAt + 3], "bottom-up BGRA data preserves the rendered image");
                    int maskAt = offset + 40 + size * size * 4 + (size - 1 - y) * maskStride + x / 8;
                    bool masked = (encoded[maskAt] & (0x80 >> (x % 8))) != 0;
                    Check(masked == (pixels[sourceAt + 3] == 0), "legacy AND mask matches alpha");
                    if (masked) transparent++; else visible++;
                }
                Check(visible > size * size / 4 && transparent > size, "icon keeps both visible artwork and transparent margins");
            }
            Check(previousEnd == encoded.Length, "ICO file has no unused trailing bytes");
        }
        Console.WriteLine($"Tray icon: {assertions} assertions passed (pose synchronization and ICO pixels; no native shell execution).");
    }

    public static void ExportPreview(string rawPath, int width, int height, string output)
    {
        Directory.CreateDirectory(output); byte[] rgba = File.ReadAllBytes(rawPath);
        for (int frame = 0; frame < TrayIconPose.FrameCount; frame++)
            File.WriteAllBytes(Path.Combine(output, $"cat-{frame:00}.ico"), TrayIconArtwork.EncodeIcon(rgba, width, height, frame));
        // Synthetic typing samples use the production floating-head scene, not a looped substitute.
        var head = new PixelHeadScene(); var session = Guid.NewGuid(); long sequence = 0;
        using var samples = new StreamWriter(Path.Combine(output, "poses.txt"));
        for (int tick = 0; tick < 6 * 48; tick++)
        {
            double time = tick / 48d; bool pressed = tick < 4 * 48 && tick % 12 == 0;
            var events = pressed ? new[] { new KeyboardEvent(++sequence, time, KeyboardEventKind.Pressed, 30, KeyboardModifiers.None) } : Array.Empty<KeyboardEvent>();
            head.Update(new KeyboardInput(session, sequence, KeyboardState.Running, time, KeyboardModifiers.None,
                Array.Empty<HeldKey>(), time < 4 ? 4 : 0, 0, events, 0), 1d / 48);
            if (tick % 3 == 0) samples.WriteLine(TrayIconPose.FromAngle(head.Angle));
        }
    }
}
