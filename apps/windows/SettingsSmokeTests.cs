using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Plugins;

namespace Miucs.Windows;

internal static class SettingsSmokeTests
{
    internal static void Run(string output)
    {
        string temporary = Path.Combine(Path.GetTempPath(), "miucs-settings-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        SettingsWindow? window = null;
        try
        {
            using var plugins = new PluginHost(new AudioChannel(), new KeyboardChannel(), user: temporary, include: id => !SkinCatalog.IsRetired(id));
            Check(plugins.Views.ContainsKey("pixel-keyboard") && !plugins.Views.Keys.Any(SkinCatalog.IsRetired), "supported plugin-only catalog");
            var original = plugins.Views["pixel-keyboard"];
            var skins = Enumerable.Range(0, 12).Select(i => original with { Id = "skin-" + i, Name = "测试皮肤 " + i }).ToArray();
            string selected = skins[0].Id;
            var state = new SettingsState(skins, selected, true, false, 38, 10, 200, 70, false, true, "音频已连接", "stopped", "");
            window = new SettingsWindow(new SettingsActions
            {
                SelectSkin = id => { selected = id; state = state with { SelectedId = id }; window!.UpdateState(state); }
            });
            window.UpdateState(state); window.Show(); Pump(); window.UpdateLayout();
            Check(window.ShowInTaskbar, "settings appear in the taskbar");
            var navigation = (RadioButton)window.FindName("AppearanceNavigation");
            Check(Hit<RadioButton>(window, navigation, new(navigation.ActualWidth - 7, navigation.ActualHeight / 2)) == navigation, "sidebar trailing whitespace hits the entire row");
            navigation.IsChecked = true; window.UpdateLayout();
            Check(((FrameworkElement)window.FindName("AppearancePage")).Visibility == Visibility.Visible, "navigation opens appearance");
            ((RadioButton)window.FindName("SkinsNavigation")).IsChecked = true; window.UpdateLayout();
            var buttons = Descendants<Button>(window).Where(b => b.Tag is string id && id.StartsWith("skin-")).ToArray();
            Check(buttons.Length == skins.Length, "all cards are present");
            var card = buttons[1];
            foreach (Point point in new[] { new Point(15, 15), new Point(card.ActualWidth / 2, 90), new Point(card.ActualWidth - 12, card.ActualHeight - 14) })
                Check(Hit<Button>(window, card, point) == card, "preview, padding and title whitespace hit the card");
            card.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(selected == (string)card.Tag, "card click selects the expected skin");
            Check(Hit<Button>(window, card, new(card.ActualWidth + 6, 80)) == null, "card gap is not a button");
            var scroll = (ScrollViewer)window.FindName("PageScroll");
            scroll.ScrollToEnd(); Pump(); window.UpdateLayout();
            card = buttons[^1];
            Check(Hit<Button>(window, card, new(card.ActualWidth / 2, card.ActualHeight - 16)) == card, "scrolling moves hit target with visible card");
            card.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(selected == skins[^1].Id, "scrolled card selects expected skin");
            scroll.ScrollToTop(); Pump();
            Render(window, Path.Combine(output, "settings-skins.png"));
            foreach (string name in new[] { "AppearanceNavigation", "InputsNavigation" })
            {
                ((RadioButton)window.FindName(name)).IsChecked = true; Pump();
                Render(window, Path.Combine(output, "settings-" + name + ".png"));
            }
            window.Close(); Check(window.IsVisible && window.WindowState == WindowState.Minimized, "close keeps taskbar entry and background application");
            window.Present(); Pump(); Check(window.WindowState != WindowState.Minimized && window.IsVisible, "reopen restores settings");
            window.CloseForExit(); window = null;

            File.WriteAllBytes(Path.Combine(temporary, "preview.gif"), Convert.FromBase64String("R0lGODlhBAAEAIEAAOYoKAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQABQAAACwAAAAABAAEAAAICQABCBxIsCCAgAAh+QQBDAABACwAAAAABAAEAIEeUOYAAAAAAAAAAAAICQABCBxIsCCAgAA7"));
            var preview = new SkinPreview { DirectoryPath = temporary, Width = 120, Height = 80 };
            var owner = new Window { Width = 150, Height = 120, Content = preview, ShowInTaskbar = false };
            try
            {
                owner.Show(); Pump();
                Check(preview.FrameCount == 2 && preview.AnimationRunning && !preview.IsHitTestVisible, "GIF animates without stealing mouse input");
                var before = preview.Source; preview.AdvanceFrame(); Check(!ReferenceEquals(before, preview.Source), "GIF frame advances");
                owner.WindowState = WindowState.Minimized; Pump(); Check(!preview.AnimationRunning, "minimized preview stops its timer");
                owner.WindowState = WindowState.Normal; Pump(); Check(preview.AnimationRunning, "restored preview resumes its timer");
                owner.Hide(); Pump(); Check(!preview.AnimationRunning, "hidden preview stops its timer");
            }
            finally { owner.Close(); }
            File.WriteAllText(Path.Combine(temporary, "preview.gif"), "invalid GIF");
            File.Copy(Path.Combine(original.Directory, "preview.png"), Path.Combine(temporary, "preview.png"));
            var fallback = new SkinPreview { DirectoryPath = temporary };
            Check(fallback.FrameCount == 1, "corrupt GIF falls back to a valid PNG");
            Console.WriteLine("PASS native settings: full-row/card hit targets, scroll, callbacks, taskbar reopen, GIF lifecycle and preview fallback");
        }
        finally { window?.CloseForExit(); Directory.Delete(temporary, true); }
    }
    private static void Check(bool condition, string message)
    { if (!condition) throw new InvalidOperationException("Settings UI: " + message); }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T item) yield return item;
            foreach (var descendant in Descendants<T>(child)) yield return descendant;
        }
    }
    private static T? Hit<T>(Window window, FrameworkElement element, Point point) where T : DependencyObject
    {
        var hit = window.InputHitTest(element.TranslatePoint(point, window)) as DependencyObject;
        while (hit != null) { if (hit is T expected) return expected; hit = VisualTreeHelper.GetParent(hit); }
        return null;
    }
    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ContextIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
    private static void Render(Window window, string path)
    {
        window.UpdateLayout();
        var content = (FrameworkElement)window.Content;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(content); var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path); encoder.Save(file);
    }
}
