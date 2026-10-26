using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Buffers.Binary;

namespace Miucs.Audio;

/// <summary>WAVEFORMATEX / EXTENSIBLE decoding. The source's actual rate and channel count are retained.</summary>
public sealed record PcmFormat(int SampleRate, int Channels, int BitsPerSample, int BlockAlign, bool FloatingPoint)
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
        if (channels is < 1 or > 2) throw new NotSupportedException("Use a mono or stereo Windows playback format.");
        if (rate is < 8000 or > 192000 || align != channels * bits / 8 ||
            (floating ? bits != 32 : tag != 1 || bits is not (16 or 24 or 32)))
            throw new NotSupportedException("Unsupported playback PCM format.");
        return new(rate, channels, bits, align, floating);
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
}
