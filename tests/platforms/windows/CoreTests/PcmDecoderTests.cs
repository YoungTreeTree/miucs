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
        var surround = PcmFormat.Parse(Wave(1, 16, 6));
        Check(surround.Channels == 6, "surround format is retained for downmix");
        byte[] packet = new byte[12];
        packet[0] = 0xff; packet[1] = 0x7f;
        var mixed = surround.DownmixToStereo(surround.Decode(packet, 1));
        Check(mixed.Length == 2 && mixed[0] > .99f && Math.Abs(mixed[1]) < .01f, "5.1 front left stays on the left");
        packet = new byte[12]; packet[4] = 0xff; packet[5] = 0x7f;
        mixed = surround.DownmixToStereo(surround.Decode(packet, 1));
        Check(mixed[0] > .7f && mixed[1] > .7f, "center reaches both analysis channels");
        var adapter = new AnalysisRateAdapter();
        var fast = new float[19200];
        for (int i = 0; i < fast.Length; i++) fast[i] = 0.5f;
        var slow = adapter.Process(fast, 192000, 1);
        Check(slow.Length > 4700 && slow.Length < 4900, "192 kHz tenth-second becomes 48 kHz");
        Check(slow[^1] > .4f && slow[^1] < .6f, "resampled level stays near the source");
        bool threw = false; try { pcm.Decode(new byte[1], 1); } catch (ArgumentException) { threw = true; }
        Check(threw, "truncated packet rejected");
        Console.WriteLine($"PCM decoder tests: {count} assertions passed.");
    }
}
