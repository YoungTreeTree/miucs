using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;

namespace Miucs.Windows;

/// <summary>Native WPF rendering and isolated hover-window tests. Synthetic data only; never starts capture or changes user preferences.</summary>
internal static class WindowsSmokeTests
{
    public static void Run(string output)
    {
        Directory.CreateDirectory(output);
        VerifyLockGlyph(output);
        VerifyHoverLockWindow();
        VerifyStaffTraceGeometry();
        foreach (var factory in new Func<VisualizationView>[] { () => new PencilFlightView(), () => new StaffNoteView(), () => new PixelKeyboardView() })
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
            if (drawn < 100 || transparent < pixels.Length / (view.Id == "pixel-keyboard" ? 40 : 8)) throw new InvalidOperationException(view.Id + " failed transparent drawing coverage");
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
        File.WriteAllText(Path.Combine(output, "result.json"), "{\"nativeWpfOffscreen\":\"passed\",\"realLoopback\":\"not-run\",\"realKeyboard\":\"not-run\",\"desktopWindow\":\"not-run\",\"syntheticHoverWindow\":\"passed\"}\n");
    }
    private static void VerifyStaffTraceGeometry()
    {
        var scene = new StaffNoteScene();
        var audio = new AudioChannel(); var keyboard = new KeyboardChannel();
        Guid session = audio.BeginSession(AudioState.Running);
        using var sounds = audio.Subscribe(); using var keys = keyboard.Subscribe();
        audio.Publish(session, new AudioFeatures
        {
            Time = 0, SampleRate = 48000, ChannelCount = 2, Envelope = .2, IsSilent = false
        }, null, 0);
        scene.Update(sounds.Read(0), keys.Read(0), 0);
        // A horizontal missing interval isolates native path joins from other decoration.
        scene.Trace.Add(new TracePoint(-1, 110, 1, 0, 0));
        scene.Trace.Add(new TracePoint(-.1, 110, 1, 0, .2));
        scene.Update(sounds.Read(.1), keys.Read(.1), .1);
        var growing = StaffNoteView.CreateTraceGeometry(scene).GetFlattenedPathGeometry();
        if (growing.Figures.Count != 2) throw new InvalidOperationException("Staff join must grow from two endpoints");
        scene.Update(sounds.Read(.21), keys.Read(.21), .11);
        var geometry = StaffNoteView.CreateTraceGeometry(scene);
        if (geometry.GetFlattenedPathGeometry().Figures.Count != 1)
            throw new InvalidOperationException("Staff join must settle into one WPF figure");
        foreach (double scale in new[] { .8, 1.0, 2.0 })
        {
            var drawing = new DrawingVisual();
            using (var dc = drawing.RenderOpen())
            {
                dc.PushTransform(new ScaleTransform(scale, scale));
                dc.DrawGeometry(null, new Pen(Brushes.Black, 1.05), geometry);
                dc.Pop();
            }
            int width = (int)(800 * scale), height = (int)(160 * scale);
            var image = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            image.Render(drawing);
            var pixels = new byte[width * height * 4]; image.CopyPixels(pixels, width * 4, 0);
            int left = (int)Math.Ceiling((640 - (scene.Elapsed + 1) * 70) * scale) + 1;
            int right = (int)Math.Floor((640 - (scene.Elapsed + .1) * 70) * scale) - 1;
            for (int x = left; x <= right; x++)
            {
                bool ink = false;
                for (int y = (int)(108 * scale); y <= (int)(112 * scale); y++)
                    ink |= pixels[(y * width + x) * 4 + 3] > 0;
                if (!ink) throw new InvalidOperationException("Settled staff curve has a transparent column");
            }
        }
    }

    private static void VerifyLockGlyph(string output)
    {
        byte[]? lockedPixels = null;
        foreach (bool locked in new[] { true, false })
        {
            var glyph = new LockGlyph { Locked = locked, Width = 36, Height = 36 };
            glyph.Measure(new Size(36, 36)); glyph.Arrange(new Rect(0, 0, 36, 36)); glyph.UpdateLayout();
            var image = new RenderTargetBitmap(36, 36, 96, 96, PixelFormats.Pbgra32);
            image.Render(glyph);
            var pixels = new byte[36 * 36 * 4]; image.CopyPixels(pixels, 36 * 4, 0);
            int ink = 0;
            for (int i = 0; i < pixels.Length; i += 4)
                if (pixels[i + 3] > 200 && pixels[i] < 130) ink++;
            if (ink < 20) throw new InvalidOperationException("Lock glyph missing pencil strokes");
            if (locked) lockedPixels = pixels;
            else
            {
                int changed = 0;
                for (int i = 0; i < pixels.Length; i++) if (pixels[i] != lockedPixels![i]) changed++;
                if (changed < 15) throw new InvalidOperationException("Lock/unlock glyphs indistinguishable");
            }
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(image));
            using var file = File.Create(Path.Combine(output, locked ? "hover-locked.png" : "hover-unlocked.png"));
            encoder.Save(file);
        }
    }

    private static void VerifyHoverLockWindow()
    {
        var owner = new Window
        {
            Width = 200, Height = 140, Left = 20, Top = 20, WindowStyle = WindowStyle.None,
            AllowsTransparency = true, Background = Brushes.Transparent, ShowActivated = false,
            ShowInTaskbar = false, Content = new System.Windows.Controls.Grid()
        };
        owner.Show();
        NativeWindow.SetInteractive(owner, false);
        bool adjusting = false, available = true;
        HoverLockControl? hover = null;
        try
        {
            hover = new HoverLockControl(owner, () => available, () =>
            {
                adjusting = !adjusting;
                NativeWindow.SetInteractive(owner, adjusting);
                hover!.SetLocked(!adjusting);
            }, pollPointer: false);
            Assert(!hover.TargetWindow.IsVisible, "hidden before dwell");
            for (int i = 0; i < 30; i++) hover.Sample(i * .1, true);
            Assert(!hover.TargetWindow.IsVisible, "hidden before 3 seconds");
            hover.Sample(3, true);
            Assert(hover.TargetWindow.IsVisible, "visible at 3 seconds");
            Assert(NativeWindow.IsClickThrough(owner), "revealing does not intercept canvas");
            Assert(!NativeWindow.IsClickThrough(hover.TargetWindow), "only lock target interactive");
            Assert(hover.TargetWindow.ActualWidth >= 32 && hover.TargetWindow.ActualWidth <= 36 &&
                hover.TargetWindow.ActualHeight >= 32 && hover.TargetWindow.ActualHeight <= 36,
                "interactive target remains small");
            for (int i = 0; i < 20; i++)
            {
                hover.ClickForVerification();
                Assert(NativeWindow.IsClickThrough(owner) == !adjusting, "click updates native click-through state");
                Assert(hover.TargetWindow.IsVisible, "toggle does not flicker");
            }
            Assert(!adjusting, "even number of toggles relocks");
            hover.ClickForVerification();
            hover.Sample(3.05, false);
            Assert(hover.TargetWindow.IsVisible, "unlocked target stays visible outside canvas");
            hover.ClickForVerification();
            hover.Sample(3.1, false);
            Assert(!hover.TargetWindow.IsVisible, "leave hides target");
            adjusting = true; NativeWindow.SetInteractive(owner, true); hover.SetLocked(false);
            Assert(hover.TargetWindow.IsVisible, "menu unlock immediately reveals target");
            hover.ClickForVerification(); hover.Sample(3.2, false);
            for (int i = 0; i < 30; i++) hover.Sample(4 + i * .1, true);
            Assert(!hover.TargetWindow.IsVisible, "reentry must dwell again");
            hover.Sample(7, true);
            Assert(hover.TargetWindow.IsVisible, "reentry reveals");
            owner.Width = 280; owner.Height = 180; owner.Left = 40; owner.UpdateLayout();
            hover.Sample(7.1, true);
            Assert(hover.TargetWindow.Owner == owner, "target follows owner lifecycle");
            var expected = owner.PointToScreen(new Point((owner.ActualWidth - 34) / 2, Math.Max(4, owner.ActualHeight * .28 - 17)));
            var actual = hover.TargetWindow.PointToScreen(new Point(0, 0));
            Assert(Math.Abs(expected.X - actual.X) <= 2 && Math.Abs(expected.Y - actual.Y) <= 2,
                "target follows physical owner position and scale");
            available = false; hover.Sample(7.2, true);
            Assert(!hover.TargetWindow.IsVisible, "suspend hides target");
            available = true;
            for (int i = 0; i <= 30; i++) hover.Sample(8 + i * .1, true);
            Assert(hover.TargetWindow.IsVisible, "resume fresh dwell");
            hover.Reset();
            Assert(!hover.TargetWindow.IsVisible, "explicit reset hides target");
            owner.Hide(); hover.Sample(12, true);
            Assert(!hover.TargetWindow.IsVisible, "hidden owner never reveals target");
        }
        finally { hover?.Dispose(); owner.Close(); }
    }

    private static void Assert(bool result, string message)
    { if (!result) throw new InvalidOperationException("Hover lock: " + message); }

}
