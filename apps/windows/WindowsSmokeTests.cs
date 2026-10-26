using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;

namespace Miucs.Windows;

/// <summary>Native WPF offscreen tests. Synthetic data only; never starts capture or changes user preferences.</summary>
internal static class WindowsSmokeTests
{
    public static void Run(string output)
    {
        Directory.CreateDirectory(output);
        foreach (var factory in new Func<VisualizationView>[] { () => new PencilFlightView(), () => new StaffNoteView() })
        {
            using var view = factory();
            var audio = new AudioChannel(); var keyboard = new KeyboardChannel();
            Guid audioSession = audio.BeginSession(AudioState.Running), keySession = keyboard.BeginSession(KeyboardState.Running);
            using var sounds = audio.Subscribe(); using var keys = keyboard.Subscribe();
            view.Width = view.BaseWidth; view.Height = view.BaseHeight;
            view.Measure(new Size(view.Width, view.Height)); view.Arrange(new Rect(0, 0, view.Width, view.Height));
            view.ApplyAppearance(Color.FromRgb(0x3D, 0x3D, 0x3D)); view.Activate();
            for (int i = 1; i <= 180; i++)
            {
                double time = i / 60.0;
                audio.Publish(audioSession, new AudioFeatures
                {
                    Time = time, SampleRate = 48000, ChannelCount = 2, Rms = .15, RmsDBFS = -16.48,
                    Peak = .3, Envelope = .15 + .05 * Math.Sin(time * 2), IsSilent = false,
                    MidEnergy = .02, LowEnergy = .01, HighEnergy = .001, BandwidthHz = 2500,
                    SpectralFlux = i % 30 == 0 ? .5 : .01, IsOnset = i % 30 == 0
                }, new MelodyFrame(time, 440 * Math.Pow(2, (i / 40 % 4) / 12.0), .95, true), time);
                if (i % 12 == 0) keyboard.Publish(keySession, 0x1E, true, KeyboardModifiers.None, time);
                if (i % 12 == 1) keyboard.Publish(keySession, 0x1E, false, KeyboardModifiers.None, time);
                view.Update(sounds.Read(time), keys.Read(time), 1.0 / 60);
            }
            view.UpdateLayout();
            var image = new RenderTargetBitmap((int)view.Width, (int)view.Height, 96, 96, PixelFormats.Pbgra32);
            image.Render(view);
            var pixels = new byte[(int)view.Width * (int)view.Height * 4]; image.CopyPixels(pixels, (int)view.Width * 4, 0);
            int drawn = 0, transparent = 0;
            for (int i = 3; i < pixels.Length; i += 4) { if (pixels[i] > 0) drawn++; else transparent++; }
            if (drawn < 100 || transparent < pixels.Length / 8) throw new InvalidOperationException(view.Id + " failed transparent drawing coverage");
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using (var file = File.Create(Path.Combine(output, view.Id + ".png"))) encoder.Save(file);
            view.Deactivate(); view.Deactivate(); view.Activate();
            view.ApplyAppearance(Color.FromRgb(0x4F, 0x70, 0x87));
            foreach (double scale in new[] { .8, 2.0 })
            {
                view.Width = view.BaseWidth * scale; view.Height = view.BaseHeight * scale;
                view.Measure(new Size(view.Width, view.Height)); view.Arrange(new Rect(0, 0, view.Width, view.Height)); view.UpdateLayout();
                var colored = new RenderTargetBitmap((int)view.Width, (int)view.Height, 96, 96, PixelFormats.Pbgra32);
                colored.Render(view);
                var recolored = new byte[(int)view.Width * (int)view.Height * 4]; colored.CopyPixels(recolored, (int)view.Width * 4, 0);
                int blue = 0;
                for (int i = 0; i < recolored.Length; i += 4)
                    if (recolored[i + 3] > 32 && recolored[i] > recolored[i + 2]) blue++;
                if (blue < 100) throw new InvalidOperationException(view.Id + " color/resize/resume rendering failed");
            }
            view.Dispose(); view.Dispose();
        }
        File.WriteAllText(Path.Combine(output, "result.json"), "{\"nativeWpfOffscreen\":\"passed\",\"realLoopback\":\"not-run\",\"realKeyboard\":\"not-run\",\"desktopWindow\":\"not-run\"}\n");
    }
}
