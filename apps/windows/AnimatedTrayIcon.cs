using System;
using System.Drawing;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

namespace Miucs.Windows;

/// <summary>Owns a bounded set of icons. Ticks select a cached pose of the application cat, independent of plugins.</summary>
internal sealed class AnimatedTrayIcon : IDisposable
{
    private readonly Forms.NotifyIcon tray;
    private readonly Func<double> sampleAngle;
    private readonly DispatcherTimer timer;
    private readonly byte[][] encodedFrames = new byte[TrayIconPose.FrameCount][];
    private Icon[] frames = Array.Empty<Icon>();
    private Size size;
    private bool running, disposed;
    internal int Frame { get; private set; } = TrayIconPose.RestFrame;

    public AnimatedTrayIcon(Forms.NotifyIcon tray, Func<double> sampleAngle)
    {
        this.tray = tray; this.sampleAngle = sampleAngle;
        using var stream = typeof(AnimatedTrayIcon).Assembly.GetManifestResourceStream("Miucs.PixelCatHead.png")
            ?? throw new InvalidOperationException("Missing bundled pixel cat portrait");
        var image = BitmapFrame.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        var converted = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var rgba = new byte[converted.PixelWidth * converted.PixelHeight * 4];
        converted.CopyPixels(rgba, converted.PixelWidth * 4, 0);
        for (int i = 0; i < rgba.Length; i += 4) (rgba[i], rgba[i + 2]) = (rgba[i + 2], rgba[i]);
        for (int frame = 0; frame < encodedFrames.Length; frame++)
            encodedFrames[frame] = TrayIconArtwork.EncodeIcon(rgba, converted.PixelWidth, converted.PixelHeight, frame);
        RefreshSize();
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromSeconds(TrayIconPose.UpdateInterval) };
        timer.Tick += OnTick;
    }

    public void SetRunning(bool value)
    {
        if (disposed) return;
        running = value;
        if (value) { Refresh(); timer.Start(); }
        else { timer.Stop(); Select(TrayIconPose.RestFrame); }
    }
    private void OnTick(object? sender, EventArgs e) => Refresh();
    internal void Refresh()
    {
        if (!disposed && running) Select(TrayIconPose.FromAngle(sampleAngle()));
    }
    private void Select(int frame)
    {
        if (Frame == frame && tray.Icon != null) return;
        Frame = frame; tray.Icon = frames[frame];
    }
    public void RefreshSize()
    {
        if (disposed) return;
        var requested = Forms.SystemInformation.SmallIconSize;
        if (requested == size && frames.Length > 0) return;
        var replacement = new Icon[encodedFrames.Length];
        try
        {
            for (int i = 0; i < replacement.Length; i++)
            {
                using var stream = new MemoryStream(encodedFrames[i], writable: false);
                using var icon = new Icon(stream, requested);
                replacement[i] = (Icon)icon.Clone();
            }
            tray.Icon = replacement[Frame];
        }
        catch { foreach (var icon in replacement) icon?.Dispose(); throw; }
        var old = frames; frames = replacement; size = requested;
        foreach (var icon in old) icon.Dispose();
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; timer.Stop(); timer.Tick -= OnTick;
        tray.Icon = null;
        foreach (var icon in frames) icon.Dispose();
        frames = Array.Empty<Icon>();
    }
}
