using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Buffers.Binary;

namespace Miucs.Audio;

/// <summary>WAVEFORMATEX / EXTENSIBLE decoding. The source's actual rate and channel count are retained.</summary>
public sealed record PcmFormat(int SampleRate, int Channels, int BitsPerSample, int BlockAlign, bool FloatingPoint, int ChannelMask = 0)
{
    public static PcmFormat Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 18) throw new NotSupportedException("Incomplete WAVEFORMATEX.");
        int tag = BinaryPrimitives.ReadUInt16LittleEndian(bytes);
        int channels = BinaryPrimitives.ReadUInt16LittleEndian(bytes[2..]);
        int rate = BinaryPrimitives.ReadInt32LittleEndian(bytes[4..]);
        int align = BinaryPrimitives.ReadUInt16LittleEndian(bytes[12..]);
        int bits = BinaryPrimitives.ReadUInt16LittleEndian(bytes[14..]);
        int extra = BinaryPrimitives.ReadUInt16LittleEndian(bytes[16..]);
        if (tag == 0xfffe)
        {
            if (extra < 22 || bytes.Length < 40) throw new NotSupportedException("Incomplete WAVEFORMATEXTENSIBLE.");
            var sub = new Guid(bytes.Slice(24, 16));
            if (sub == new Guid("00000001-0000-0010-8000-00aa00389b71")) tag = 1;
            else if (sub == new Guid("00000003-0000-0010-8000-00aa00389b71")) tag = 3;
            else throw new NotSupportedException("Unsupported audio encoding.");
        }
        bool floating = tag == 3;
        if (channels is < 1 or > 18) throw new NotSupportedException("Unsupported channel count.");
        if (rate is < 8000 or > 192000 || align != channels * bits / 8 ||
            (floating ? bits != 32 : tag != 1 || bits is not (16 or 24 or 32)))
            throw new NotSupportedException("Unsupported playback PCM format.");
        int mask = 0;
        if (bytes[0] == 0xfe && bytes[1] == 0xff && bytes.Length >= 24) mask = BinaryPrimitives.ReadInt32LittleEndian(bytes[20..]);
        return new(rate, channels, bits, align, floating, mask);
    }
    public float[] Decode(ReadOnlySpan<byte> bytes, int frameCount, bool silent = false)
    {
        if (frameCount < 0 || frameCount > SampleRate * 2) throw new ArgumentOutOfRangeException(nameof(frameCount));
        var result = new float[checked(frameCount * Channels)];
        if (silent) return result;
        if (bytes.Length < checked(frameCount * BlockAlign)) throw new ArgumentException("Truncated PCM packet.");
        int size = BitsPerSample / 8;
        for (int i = 0, p = 0; i < result.Length; i++, p += size)
        {
            float sample;
            if (FloatingPoint) sample = BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(bytes[p..]));
            else if (BitsPerSample == 16) sample = BinaryPrimitives.ReadInt16LittleEndian(bytes[p..]) / 32768f;
            else if (BitsPerSample == 24)
            {
                int n = bytes[p] | bytes[p + 1] << 8 | bytes[p + 2] << 16;
                sample = ((n << 8) >> 8) / 8388608f;
            }
            else sample = BinaryPrimitives.ReadInt32LittleEndian(bytes[p..]) / 2147483648f;
            result[i] = float.IsFinite(sample) ? sample : 0;
        }
        return result;
    }

    /// <summary>Fold surround into the stereo pair the analyzers already understand. Mono and stereo pass through.</summary>
    public float[] DownmixToStereo(float[] interleaved)
    {
        if (Channels <= 2) return interleaved;
        int frames = interleaved.Length / Channels;
        var stereo = new float[frames * 2];
        var gain = ChannelGains(Channels, ChannelMask);
        for (int frame = 0, source = 0; frame < frames; frame++)
        {
            float left = 0, right = 0;
            for (int channel = 0; channel < Channels; channel++, source++)
            {
                left += interleaved[source] * gain[channel].Left;
                right += interleaved[source] * gain[channel].Right;
            }
            stereo[frame * 2] = left;
            stereo[frame * 2 + 1] = right;
        }
        return stereo;
    }

    private static (float Left, float Right)[] ChannelGains(int channels, int mask)
    {
        uint bits = mask > 0 ? (uint)mask : channels switch { 6 => 0x3Fu, 8 => 0x63Fu, _ => 0u };
        var gain = new (float Left, float Right)[channels];
        int index = 0;
        if (bits != 0)
        {
            for (int bit = 0; bit < 32 && index < channels; bit++)
            {
                if ((bits & (1u << bit)) == 0) continue;
                gain[index++] = SpeakerGain(1u << bit);
            }
        }
        while (index < channels) gain[index++] = (0.5f, 0.5f);
        return gain;
    }

    private static (float Left, float Right) SpeakerGain(uint speaker) => speaker switch
    {
        0x1 => (1, 0),          // front left
        0x2 => (0, 1),          // front right
        0x4 => (0.707f, 0.707f), // front center
        0x8 => (0.5f, 0.5f),    // LFE, kept so bass-only material still drives the visual
        0x10 => (0.707f, 0),    // back left
        0x20 => (0, 0.707f),    // back right
        0x40 => (0.707f, 0.2f), // front left of center
        0x80 => (0.2f, 0.707f), // front right of center
        0x100 => (0.5f, 0.5f),  // back center
        0x200 => (0.707f, 0),   // side left
        0x400 => (0, 0.707f),   // side right
        _ => (0.5f, 0.5f)
    };
}

/// <summary>
/// Streams device-rate PCM to 48 kHz before analysis. macOS capture is fixed at 48 kHz;
/// a 192 kHz device otherwise makes the 2048-point window only 11 ms and the beat tracker never locks.
/// </summary>
public sealed class AnalysisRateAdapter
{
    public const int TargetRate = 48000;
    private float[] low1 = Array.Empty<float>(), low2 = Array.Empty<float>(), low3 = Array.Empty<float>(), hold = Array.Empty<float>();
    private long origin;
    private double next;
    private bool primed;

    public void Reset()
    {
        low1 = low2 = low3 = hold = Array.Empty<float>();
        origin = 0; next = 0; primed = false;
    }

    public float[] Process(float[] interleaved, int rate, int channels)
    {
        if (rate == TargetRate) return interleaved;
        if (channels < 1 || interleaved.Length % channels != 0) throw new ArgumentException("Incomplete PCM.");
        if (low1.Length != channels) Reset();
        if (low1.Length != channels)
        {
            low1 = new float[channels]; low2 = new float[channels]; low3 = new float[channels]; hold = new float[channels];
        }
        int frames = interleaved.Length / channels;
        var low = new float[interleaved.Length];
        float alpha = (float)(1 - Math.Exp(-2 * Math.PI * Math.Min(8000, TargetRate * 0.45) / rate));
        for (int frame = 0, index = 0; frame < frames; frame++)
        {
            for (int channel = 0; channel < channels; channel++, index++)
            {
                float sample = interleaved[index];
                low1[channel] += (sample - low1[channel]) * alpha;
                low2[channel] += (low1[channel] - low2[channel]) * alpha;
                low3[channel] += (low2[channel] - low3[channel]) * alpha;
                low[index] = low3[channel];
            }
        }
        if (!primed) { next = 0; primed = true; }
        double step = (double)rate / TargetRate;
        var output = new List<float>();
        while (next < origin + frames)
        {
            double position = next - origin;
            int left = (int)Math.Floor(position);
            float fraction = (float)(position - left);
            int right = left + 1;
            for (int channel = 0; channel < channels; channel++)
            {
                float a = left >= 0 ? low[left * channels + channel] : hold[channel];
                float b = right < frames ? low[right * channels + channel] : a;
                output.Add(a + (b - a) * fraction);
            }
            next += step;
        }
        if (frames > 0)
            for (int channel = 0; channel < channels; channel++) hold[channel] = low[(frames - 1) * channels + channel];
        origin += frames;
        return output.ToArray();
    }
}
