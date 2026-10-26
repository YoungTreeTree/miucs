using System;

namespace Miucs.Audio;

/// <summary>Radix-2 double precision FFT; forward transform is unnormalized.</summary>
internal static class Spectrum
{
    public static double[] Power(double[][] samples, bool normalized)
    {
        int n = samples[0].Length;
        var result = new double[n / 2 + 1];
        double windowSquares = 0;
        var window = new double[n];
        for (int i = 0; i < n; i++) { window[i] = .5 - .5 * Math.Cos(2 * Math.PI * i / n); windowSquares += window[i] * window[i]; }
        foreach (var channel in samples)
        {
            double mean = 0;
            foreach (double x in channel) mean += x;
            mean /= n;
            var real = new double[n]; var imaginary = new double[n];
            for (int i = 0; i < n; i++) real[i] = (channel[i] - mean) * window[i];
            Forward(real, imaginary);
            for (int k = 0; k < result.Length; k++)
            {
                double scale = normalized ? (k == 0 || k == n / 2 ? 1.0 : 2.0) / (n * windowSquares) : 1;
                result[k] += (real[k] * real[k] + imaginary[k] * imaginary[k]) * scale / samples.Length;
            }
        }
        return result;
    }
    public static void Forward(double[] real, double[] imaginary)
    {
        int n = real.Length;
        if (n < 2 || (n & (n - 1)) != 0 || imaginary.Length != n) throw new ArgumentException("FFT requires equal power-of-two arrays.");
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (real[i], real[j]) = (real[j], real[i]); (imaginary[i], imaginary[j]) = (imaginary[j], imaginary[i]); }
        }
        for (int length = 2; length <= n; length <<= 1)
        {
            double angle = -2 * Math.PI / length, wrStep = Math.Cos(angle), wiStep = Math.Sin(angle);
            for (int start = 0; start < n; start += length)
            {
                double wr = 1, wi = 0;
                for (int j = 0; j < length / 2; j++)
                {
                    int a = start + j, b = a + length / 2;
                    double tr = real[b] * wr - imaginary[b] * wi, ti = real[b] * wi + imaginary[b] * wr;
                    real[b] = real[a] - tr; imaginary[b] = imaginary[a] - ti;
                    real[a] += tr; imaginary[a] += ti;
                    (wr, wi) = (wr * wrStep - wi * wiStep, wr * wiStep + wi * wrStep);
                }
            }
        }
    }
}
