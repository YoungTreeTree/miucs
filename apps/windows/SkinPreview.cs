using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Drawing = System.Drawing;
using Imaging = System.Drawing.Imaging;

namespace Miucs.Windows;

/// Package artwork only: never creates a plugin worker or subscribes to input.
public sealed class SkinPreview : Image
{
    public static readonly DependencyProperty DirectoryPathProperty = DependencyProperty.Register(nameof(DirectoryPath), typeof(string), typeof(SkinPreview),
        new PropertyMetadata(null, (target, _) => ((SkinPreview)target).LoadPreview()));
    public string? DirectoryPath { get => (string?)GetValue(DirectoryPathProperty); set => SetValue(DirectoryPathProperty, value); }
    private readonly List<(BitmapSource Image, TimeSpan Delay)> frames = new();
    private readonly DispatcherTimer timer;
    private int frame;
    internal int FrameCount => frames.Count;
    internal bool AnimationRunning => timer.IsEnabled;
    public SkinPreview()
    {
        IsHitTestVisible = false; Stretch = Stretch.Uniform;
        timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) => AdvanceFrame();
        Loaded += (_, _) => UpdateAnimation(); Unloaded += (_, _) => timer.Stop();
        IsVisibleChanged += (_, _) => UpdateAnimation();
    }
    internal void AdvanceFrame()
    {
        if (frames.Count < 2) return;
        frame = (frame + 1) % frames.Count; Source = frames[frame].Image; timer.Interval = frames[frame].Delay;
    }
    private void UpdateAnimation()
    {
        if (frames.Count > 1 && IsLoaded && IsVisible) timer.Start(); else timer.Stop();
    }
    private void LoadPreview()
    {
        timer.Stop(); frames.Clear(); frame = 0; Source = null;
        if (DirectoryPath != null)
        foreach (string path in SkinCatalog.PreviewCandidates(DirectoryPath))
        {
            try
            {
                if (Path.GetExtension(path).Equals(".gif", StringComparison.OrdinalIgnoreCase)) LoadGif(path);
                else
                {
                    using var stream = File.OpenRead(path);
                    var bitmap = new BitmapImage(); bitmap.BeginInit(); bitmap.CacheOption = BitmapCacheOption.OnLoad;
                    bitmap.DecodePixelWidth = 520; bitmap.StreamSource = stream; bitmap.EndInit(); bitmap.Freeze();
                    frames.Add((bitmap, TimeSpan.FromMilliseconds(100)));
                }
                if (frames.Count > 0) break;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException or FileFormatException or ExternalException)
            { frames.Clear(); }
        }
        if (frames.Count > 0) { Source = frames[0].Image; timer.Interval = frames[0].Delay; }
        else
        {
            // Keep missing/corrupt previews visible without stealing the button's hit target.
            var drawing = new GeometryDrawing(Brushes.LightGray, new Pen(Brushes.Gray, 1), new RectangleGeometry(new Rect(0, 0, 90, 52), 5, 5));
            var placeholder = new DrawingImage(drawing); placeholder.Freeze(); Source = placeholder;
        }
        UpdateAnimation();
    }
    private void LoadGif(string path)
    {
        using var stream = File.OpenRead(path);
        using var image = Drawing.Image.FromStream(stream);
        if ((long)image.Width * image.Height > 16_000_000) throw new NotSupportedException("Preview dimensions exceed limit");
        var dimension = new Imaging.FrameDimension(image.FrameDimensionsList[0]);
        int count = image.GetFrameCount(dimension);
        double scale = Math.Min(1, 520d / image.Width);
        int width = Math.Max(1, (int)(image.Width * scale)), height = Math.Max(1, (int)(image.Height * scale));
        // Oversized animations still show their first frame; decoded caches stay bounded.
        if (count > 150 || (long)width * height * count > 20_000_000) count = 1;
        byte[]? delays = null;
        try { delays = image.GetPropertyItem(0x5100)?.Value; } catch (ArgumentException) { }
        for (int index = 0; index < count; index++)
        {
            image.SelectActiveFrame(dimension, index);
            using var bitmap = new Drawing.Bitmap(width, height, Imaging.PixelFormat.Format32bppPArgb);
            using (var graphics = Drawing.Graphics.FromImage(bitmap))
            { graphics.Clear(Drawing.Color.Transparent); graphics.DrawImage(image, 0, 0, width, height); }
            var data = bitmap.LockBits(new Drawing.Rectangle(0, 0, width, height), Imaging.ImageLockMode.ReadOnly, Imaging.PixelFormat.Format32bppPArgb);
            BitmapSource source;
            try { source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Pbgra32, null, data.Scan0, data.Stride * height, data.Stride); source.Freeze(); }
            finally { bitmap.UnlockBits(data); }
            int delay = delays != null && delays.Length >= (index + 1) * 4 ? BitConverter.ToInt32(delays, index * 4) : 10;
            frames.Add((source, TimeSpan.FromMilliseconds(Math.Clamp((long)delay * 10, 20, 10_000))));
        }
    }
}
