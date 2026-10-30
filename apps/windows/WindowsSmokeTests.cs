using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Plugins;

namespace Miucs.Windows;

/// <summary>Plugin rendering and isolated hover-window tests. Synthetic data only; never starts capture or changes user preferences.</summary>
internal static class WindowsSmokeTests
{
    public static void Run(string output)
    {
        Directory.CreateDirectory(output);
        VerifyLockGlyph(output);
        VerifyHoverLockWindow();
        VerifyHardwareClickThrough();
        VerifyTrayCat(output);
        VerifyPluginRendering();
        File.WriteAllText(Path.Combine(output, "result.json"), "{\"pluginSurface\":\"passed\",\"realLoopback\":\"not-run\",\"realKeyboard\":\"not-run\",\"syntheticHoverWindow\":\"passed\"}\n");
    }
    private static void VerifyPluginRendering()
    {
        using var host = new PluginHost(new AudioChannel(), new KeyboardChannel());
        foreach (string id in new[] { "pixel-keyboard", "muffin-puppies", "niulai-keyboard", "heiji-kazuha", "zelda-guardian", "yuru-camp", "inuyasha" })
        {
            if (!host.Views.ContainsKey(id)) throw new InvalidOperationException("Missing bundled plugin: " + id);
            using var view = new PluginView(host, id);
            view.Width = view.BaseWidth; view.Height = view.BaseHeight;
            view.Measure(new Size(view.Width, view.Height)); view.Arrange(new Rect(0, 0, view.Width, view.Height));
            view.Activate();
            var package = host.Package(host.Views[id]);
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (PluginNative.miucs_plugin_ready(package.Handle) != 1)
            {
                if (DateTime.UtcNow > deadline) throw new InvalidOperationException("Plugin startup timed out: " + id);
                System.Threading.Thread.Sleep(10);
            }
            var surface = PluginNative.miucs_surface_create(package.Handle, IntPtr.Zero, id);
            if (surface == IntPtr.Zero) throw new InvalidOperationException(PluginNative.Error(IntPtr.Zero));
            try
            {
                var pixels = new byte[400 * 260 * 4];
                if (PluginNative.miucs_surface_pixels(surface, 400, 260, pixels, (nuint)pixels.Length) != 1)
                    throw new InvalidOperationException("Plugin render failed: " + id);
                int visible = 0, transparent = 0;
                for (int i = 3; i < pixels.Length; i += 4) { if (pixels[i] > 0) visible++; else transparent++; }
                if (visible < 100 || transparent < 100) throw new InvalidOperationException("Plugin alpha coverage failed: " + id);
            }
            finally { PluginNative.miucs_surface_destroy(surface); }
            view.Deactivate(); view.Activate();
        }
    }
    private static void VerifyTrayCat(string output)
    {
        double angle = 0;
        using var tray = new System.Windows.Forms.NotifyIcon(); // Keep synthetic tests out of the real tray.
        using var animation = new AnimatedTrayIcon(tray, () => angle);
        var icons = new System.Drawing.Icon[TrayIconPose.FrameCount];
        animation.SetRunning(true);
        for (int pass = 0; pass < 20; pass++) for (int frame = 0; frame < icons.Length; frame++)
        {
            angle = TrayIconPose.Angle(frame); animation.Refresh();
            if (animation.Frame != frame || tray.Icon == null) throw new InvalidOperationException("Tray pose selection failed");
            if (pass == 0) icons[frame] = tray.Icon;
            else if (!ReferenceEquals(icons[frame], tray.Icon)) throw new InvalidOperationException("Tray tick allocated a new icon");
        }
        foreach (int frame in new[] { 0, TrayIconPose.RestFrame, TrayIconPose.FrameCount - 1 })
        {
            using var bitmap = icons[frame].ToBitmap();
            int visible = 0, transparent = 0;
            for (int y = 0; y < bitmap.Height; y++) for (int x = 0; x < bitmap.Width; x++)
            { if (bitmap.GetPixel(x, y).A > 0) visible++; else transparent++; }
            if (visible < 20 || transparent < 10) throw new InvalidOperationException("Tray icon alpha/coverage failed");
            bitmap.Save(Path.Combine(output, $"tray-cat-{frame:00}.png"), System.Drawing.Imaging.ImageFormat.Png);
        }
        animation.SetRunning(false);
        angle = .2; animation.Refresh();
        if (animation.Frame != TrayIconPose.RestFrame) throw new InvalidOperationException("Paused tray must stay upright");
        animation.SetRunning(true);
        if (animation.Frame != TrayIconPose.FromAngle(angle)) throw new InvalidOperationException("Tray resume must sample current pose");
        animation.Dispose(); animation.Dispose();
        if (tray.Icon != null) throw new InvalidOperationException("Disposed tray animator retained its icon");

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


    private static int HitAtCenter(Window window)
    {
        var point = window.PointToScreen(new Point(window.ActualWidth / 2, window.ActualHeight / 2));
        return NativeWindow.HitTest(window, (int)Math.Round(point.X), (int)Math.Round(point.Y));
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
            Assert(HitAtCenter(owner) == -1, "canvas hit test passes through");
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
            Assert(HitAtCenter(owner) == 1, "adjusting canvas accepts the pointer");
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

    private static void VerifyHardwareClickThrough()
    {
        var window = new Window
        {
            Width = 180, Height = 120, Left = 40, Top = 40, WindowStyle = WindowStyle.None,
            AllowsTransparency = false, Background = Brushes.Transparent, ShowActivated = false,
            ShowInTaskbar = false
        };
        window.Show();
        try
        {
            NativeWindow.UseHardwareTransparency(window);
            NativeWindow.SetInteractive(window, false);
            if (!NativeWindow.IsClickThrough(window) || !NativeWindow.IsLayered(window) || HitAtCenter(window) != -1)
                throw new InvalidOperationException("Hardware canvas is not click-through: style=0x" + NativeWindow.ExStyle(new System.Windows.Interop.WindowInteropHelper(window).Handle).ToString("X"));
            NativeWindow.SetInteractive(window, true);
            if (NativeWindow.IsClickThrough(window) || !NativeWindow.IsLayered(window) || HitAtCenter(window) != 1)
                throw new InvalidOperationException("Adjusting canvas lost layered input: style=0x" + NativeWindow.ExStyle(new System.Windows.Interop.WindowInteropHelper(window).Handle).ToString("X"));
            var parameters = new HwndSourceParameters("Miucs click-through probe")
            {
                Width = 80, Height = 60, WindowStyle = unchecked((int)0x80000000),
                ExtendedWindowStyle = 0x00200000 | 0x08000000 | 0x00000080 | 0x00000020 | 0x00000008
            };
            using var source = new HwndSource(parameters);
            NativeWindow.PassThroughSurface(source);
            long style = NativeWindow.ExStyle(source.Handle);
            if ((style & 0x80000) == 0 || (style & 0x20) == 0 || (style & 0x200000) == 0 || NativeWindow.HitTestHandle(source.Handle, 1, 1) != -1)
                throw new InvalidOperationException("Plugin surface click-through style lost: 0x" + style.ToString("X"));
        }
        finally { window.Close(); }
    }

    private static void Assert(bool result, string message)
    { if (!result) throw new InvalidOperationException("Hover lock: " + message); }

}
