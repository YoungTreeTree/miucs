using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Miucs.Plugins;

namespace Miucs.Windows;

internal sealed class SettingsActions
{
    public Action<string> SelectSkin { get; init; } = _ => { };
    public Action<bool> SetVisible { get; init; } = _ => { };
    public Action<double> SetScale { get; init; } = _ => { };
    public Action<double> SetOpacity { get; init; } = _ => { };
    public Action<bool> SetKeyboardEnabled { get; init; } = _ => { };
    public Action<bool> SetTrayAnimation { get; init; } = _ => { };
    public Action TogglePosition { get; init; } = () => { };
    public Action ReconnectAudio { get; init; } = () => { };
    public Action Rescan { get; init; } = () => { };
    public Action Reload { get; init; } = () => { };
    public Action OpenDirectory { get; init; } = () => { };
}

internal sealed record SettingsState(IReadOnlyList<PluginInfo> Skins, string SelectedId, bool Visible, bool Adjusting,
    double Scale, double MinScale, double MaxScale, double Opacity, bool KeyboardEnabled, bool TrayAnimationEnabled,
    string AudioStatus, string KeyboardStatus, string Error);

internal sealed class SkinCardModel : INotifyPropertyChanged
{
    internal PluginInfo Info { get; }
    public string Id => Info.Id;
    public string Name => Info.Name;
    public string Directory => Info.Directory;
    private bool selected;
    public bool IsSelected
    {
        get => selected;
        set { if (selected == value) return; selected = value; PropertyChanged?.Invoke(this, new(nameof(IsSelected))); PropertyChanged?.Invoke(this, new(nameof(SelectionDescription))); }
    }
    public string SelectionDescription => selected ? "当前皮肤" : "未选择";
    public event PropertyChangedEventHandler? PropertyChanged;
    internal SkinCardModel(PluginInfo info) { Info = info; }
}

public partial class SettingsWindow : Window
{
    private readonly SettingsActions actions;
    private List<SkinCardModel> cards = new();
    private bool refreshing = true, closingForExit;
    private WindowState restoreState = WindowState.Normal;
    public static readonly DependencyProperty CardWidthProperty = DependencyProperty.Register(nameof(CardWidth), typeof(double), typeof(SettingsWindow), new PropertyMetadata(220d));
    public double CardWidth { get => (double)GetValue(CardWidthProperty); set => SetValue(CardWidthProperty, value); }
    internal SettingsWindow(SettingsActions actions)
    {
        this.actions = actions;
        InitializeComponent();
        SkinsNavigation.IsChecked = true;
        refreshing = false;
        StateChanged += (_, _) => { if (WindowState != WindowState.Minimized) restoreState = WindowState; };
        Closing += (_, e) => { if (!closingForExit) { e.Cancel = true; WindowState = WindowState.Minimized; } };
    }
    internal void Present() { Show(); if (WindowState == WindowState.Minimized) WindowState = restoreState; Activate(); }
    internal void CloseForExit() { closingForExit = true; Close(); }
    internal void UpdateState(SettingsState state)
    {
        refreshing = true;
        try
        {
            if (!cards.Select(c => c.Info).SequenceEqual(state.Skins))
            {
                cards = state.Skins.Select(s => new SkinCardModel(s)).ToList(); SkinItems.ItemsSource = cards;
            }
            foreach (var card in cards) card.IsSelected = card.Id == state.SelectedId;
            bool available = cards.Any(c => c.IsSelected);
            EmptyMessage.Visibility = cards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            VisibleToggle.IsChecked = state.Visible; VisibleToggle.IsEnabled = available;
            ReloadButton.IsEnabled = available; AppearancePage.IsEnabled = available;
            CurrentSkin.Text = cards.FirstOrDefault(c => c.IsSelected)?.Name ?? "先在「皮肤」中选择一个皮肤。";
            ScaleSlider.Maximum = Math.Max(state.MaxScale, state.Scale);
            ScaleSlider.Minimum = Math.Min(state.MinScale, state.Scale);
            ScaleSlider.Value = state.Scale; ScaleLabel.Text = $"{state.Scale:0}%";
            OpacitySlider.Value = state.Opacity; OpacityLabel.Text = $"{state.Opacity:0}%";
            PositionButton.Content = state.Adjusting ? "完成调整" : "在桌面上调整…";
            KeyboardToggle.IsChecked = state.KeyboardEnabled; TrayToggle.IsChecked = state.TrayAnimationEnabled;
            AudioStatus.Text = state.AudioStatus;
            KeyboardStatus.Text = !state.KeyboardEnabled ? "未启用" : state.KeyboardStatus switch
            { "running" or "Running" => "已连接", "suspended" or "Suspended" => "已暂停", "secureInput" or "SecureInput" => "安全输入期间暂停", _ => state.KeyboardStatus };
            ErrorMessage.Text = state.Error;
        }
        finally { refreshing = false; }
    }
    private void Navigate(object sender, RoutedEventArgs e)
    {
        if (SkinsPage == null || sender is not RadioButton button) return;
        string page = (string)button.Tag;
        SkinsPage.Visibility = page == "skins" ? Visibility.Visible : Visibility.Collapsed;
        AppearancePage.Visibility = page == "appearance" ? Visibility.Visible : Visibility.Collapsed;
        InputsPage.Visibility = page == "inputs" ? Visibility.Visible : Visibility.Collapsed;
        AboutPage.Visibility = page == "about" ? Visibility.Visible : Visibility.Collapsed;
        VisibleToggle.Visibility = page is "skins" or "appearance" ? Visibility.Visible : Visibility.Collapsed;
        Heading.Text = button.Content.ToString();
        Subtitle.Text = page switch { "skins" => "点击卡片，使用你喜欢的皮肤。", "appearance" => "调整皮肤的大小、透明度和摆放位置。", "inputs" => "连接声音与按键，让皮肤动起来。", _ => "让音乐自己飞。" };
        PageScroll.ScrollToTop();
    }
    private void ResizeCards(object sender, SizeChangedEventArgs e)
    {
        double available = Math.Max(200, PageScroll.ActualWidth - 20);
        int columns = Math.Max(1, (int)(available / 220));
        CardWidth = Math.Clamp(available / columns - 14, 180, 260);
    }
    private void SkinClick(object sender, RoutedEventArgs e) { if (sender is Button { Tag: string id }) actions.SelectSkin(id); }
    private void VisibilityClick(object sender, RoutedEventArgs e) { if (!refreshing) actions.SetVisible(VisibleToggle.IsChecked == true); }
    private void ScaleChanged(object sender, RoutedPropertyChangedEventArgs<double> e) { if (!refreshing) actions.SetScale(e.NewValue); }
    private void OpacityChanged(object sender, RoutedPropertyChangedEventArgs<double> e) { if (!refreshing) actions.SetOpacity(e.NewValue); }
    private void KeyboardClick(object sender, RoutedEventArgs e) { if (!refreshing) actions.SetKeyboardEnabled(KeyboardToggle.IsChecked == true); }
    private void TrayClick(object sender, RoutedEventArgs e) { if (!refreshing) actions.SetTrayAnimation(TrayToggle.IsChecked == true); }
    private void PositionClick(object sender, RoutedEventArgs e) => actions.TogglePosition();
    private void ReconnectClick(object sender, RoutedEventArgs e) => actions.ReconnectAudio();
    private void RescanClick(object sender, RoutedEventArgs e) => actions.Rescan();
    private void ReloadClick(object sender, RoutedEventArgs e) => actions.Reload();
    private void OpenDirectoryClick(object sender, RoutedEventArgs e) => actions.OpenDirectory();
}
