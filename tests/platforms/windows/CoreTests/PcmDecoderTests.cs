using Miucs.Audio;
using System.Buffers.Binary;

internal static class PcmDecoderTests
{
    public static void Run()
    {
        int count = 0;
        void Check(bool ok, string label) { if (!ok) throw new Exception(label); count++; }
        byte[] Wave(ushort tag, ushort bits, ushort channels = 2)
        {
            byte[] f = new byte[40];
            BinaryPrimitives.WriteUInt16LittleEndian(f, tag);
            BinaryPrimitives.WriteUInt16LittleEndian(f.AsSpan(2), channels);
            BinaryPrimitives.WriteInt32LittleEndian(f.AsSpan(4), 48000);
            BinaryPrimitives.WriteUInt16LittleEndian(f.AsSpan(12), (ushort)(channels * bits / 8));
            BinaryPrimitives.WriteUInt16LittleEndian(f.AsSpan(14), bits);
            return f;
        }
        var pcm = PcmFormat.Parse(Wave(1, 16));
        Check(pcm.SampleRate == 48000 && pcm.Channels == 2, "actual PCM format retained");
        var values = pcm.Decode(new byte[] { 0, 128, 255, 127 }, 1);
        Check(values[0] == -1 && values[1] > .999, "signed 16-bit decode");
        pcm = PcmFormat.Parse(Wave(1, 24));
        values = pcm.Decode(new byte[] { 0, 0, 128, 255, 255, 127 }, 1);
        Check(values[0] == -1 && values[1] > .999, "signed 24-bit decode");
        pcm = PcmFormat.Parse(Wave(1, 32));
        values = pcm.Decode(new byte[] { 0, 0, 0, 128, 255, 255, 255, 127 }, 1);
        Check(values[0] == -1 && values[1] > .999, "signed 32-bit decode");
        pcm = PcmFormat.Parse(Wave(3, 32));
        byte[] floatBytes = new byte[8];
        BitConverter.GetBytes(1.25f).CopyTo(floatBytes, 0); BitConverter.GetBytes(float.NaN).CopyTo(floatBytes, 4);
        values = pcm.Decode(floatBytes, 1);
        Check(values[0] == 1.25 && values[1] == 0, "float headroom retained/nonfinite sanitized");
        Check(pcm.Decode(Array.Empty<byte>(), 3, true).All(x => x == 0), "WASAPI silent packet no pointer read");
        var ext = Wave(0xfffe, 32);
        BinaryPrimitives.WriteUInt16LittleEndian(ext.AsSpan(16), 22);
        new Guid("00000003-0000-0010-8000-00aa00389b71").ToByteArray().CopyTo(ext, 24);
        Check(PcmFormat.Parse(ext).FloatingPoint, "extensible IEEE float recognized");
        bool threw = false; try { PcmFormat.Parse(Wave(1, 16, 6)); } catch (NotSupportedException) { threw = true; }
        Check(threw, "surround explicitly unsupported not misdecoded");
        threw = false; try { pcm.Decode(new byte[1], 1); } catch (ArgumentException) { threw = true; }
        Check(threw, "truncated packet rejected");
        Console.WriteLine($"PCM decoder tests: {count} assertions passed.");
    }
}
