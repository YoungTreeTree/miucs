using System;
using System.IO;

namespace Miucs.Windows;

/// <summary>The bundled cat portrait, rotated around the same chin pivot as PixelKeyboardView.</summary>
public static class TrayIconArtwork
{
    private static readonly int[] Sizes = { 16, 20, 24, 32, 40, 48, 64 };

    public static byte[] Render(byte[] source, int width, int height, int frame, int size)
    {
        if (width <= 0 || height <= 0 || source.LongLength != (long)width * height * 4 || size is < 16 or > 64)
            throw new ArgumentException("Invalid portrait dimensions or icon size");
        double angle = TrayIconPose.Angle(frame), cosine = Math.Cos(angle), sine = Math.Sin(angle);
        double side = size * .94, left = (size - side) / 2, top = size / 32d;
        double pivotX = size / 2d, pivotY = top + side * .88;
        var pixels = new byte[size * size * 4];
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            // Inverse of the floating head's clockwise screen-space rotation. Keep hard pixel edges.
            double dx = x + .5 - pivotX, dy = y + .5 - pivotY;
            int sx = (int)Math.Floor((pivotX + dx * cosine + dy * sine - left) / side * width);
            int sy = (int)Math.Floor((pivotY - dx * sine + dy * cosine - top) / side * height);
            if (sx < 0 || sx >= width || sy < 0 || sy >= height) continue;
            int input = (sy * width + sx) * 4, output = (y * size + x) * 4;
            if (source[input + 3] < 96) continue;
            Array.Copy(source, input, pixels, output, 4);
        }
        // A one-pixel light keyline keeps the original dark cat legible on dark taskbars.
        var outlined = (byte[])pixels.Clone();
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++)
        {
            int offset = (y * size + x) * 4;
            if (pixels[offset + 3] != 0) continue;
            bool edge = (x > 0 && pixels[offset - 4 + 3] > 0) || (x + 1 < size && pixels[offset + 4 + 3] > 0) ||
                (y > 0 && pixels[offset - size * 4 + 3] > 0) || (y + 1 < size && pixels[offset + size * 4 + 3] > 0);
            if (edge) { outlined[offset] = 250; outlined[offset + 1] = 248; outlined[offset + 2] = 240; outlined[offset + 3] = 230; }
        }
        return outlined;
    }

    /// <summary>Multi-resolution 32-bit ICO with alpha and an AND mask; no temporary GDI handles.</summary>
    public static byte[] EncodeIcon(byte[] source, int width, int height, int frame)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)Sizes.Length);
        int offset = 6 + 16 * Sizes.Length;
        foreach (int size in Sizes)
        {
            int length = 40 + size * size * 4 + ((size + 31) / 32) * 4 * size;
            writer.Write((byte)size); writer.Write((byte)size); writer.Write((byte)0); writer.Write((byte)0);
            writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(length); writer.Write(offset);
            offset += length;
        }
        foreach (int size in Sizes)
        {
            byte[] rgba = Render(source, width, height, frame, size);
            int maskStride = ((size + 31) / 32) * 4;
            writer.Write(40); writer.Write(size); writer.Write(size * 2);
            writer.Write((ushort)1); writer.Write((ushort)32); writer.Write(0);
            writer.Write(size * size * 4 + maskStride * size);
            writer.Write(0); writer.Write(0); writer.Write(0); writer.Write(0);
            for (int y = size - 1; y >= 0; y--) for (int x = 0; x < size; x++)
            {
                int input = (y * size + x) * 4;
                writer.Write(rgba[input + 2]); writer.Write(rgba[input + 1]); writer.Write(rgba[input]); writer.Write(rgba[input + 3]);
            }
            for (int y = size - 1; y >= 0; y--)
            {
                var mask = new byte[maskStride];
                for (int x = 0; x < size; x++) if (rgba[(y * size + x) * 4 + 3] == 0) mask[x / 8] |= (byte)(0x80 >> (x % 8));
                writer.Write(mask);
            }
        }
        return stream.ToArray();
    }
}
