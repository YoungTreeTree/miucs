using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;
using Miucs.Audio;
using Miucs.Keyboard;
using Miucs.Visualizations;
using Miucs.Plugins;
using System.IO;
using System.Linq;
using Forms = System.Windows.Forms;

namespace Miucs.Windows;

internal sealed class DesktopHost : IDisposable
{
    private readonly Application app;
    private readonly Preferences preferences = Preferences.Load(Preferences.DefaultPath);
    private readonly AudioChannel audio = new();
    private readonly KeyboardChannel keyboard = new();
    private readonly LoopbackCapture capture;
    private readonly KeyboardCapture keyboardCapture;
    private readonly Window window;
    private readonly SettingsWindow settingsWindow;
    private string shellError = "";
    private readonly HoverLockControl hoverLock;
    private readonly Grid root = new();
    private readonly Border adjustment;
    private readonly TextBlock status;
    private readonly Forms.NotifyIcon tray;
    private readonly AnimatedTrayIcon trayAnimation;
    private readonly PluginHost? pluginHost;
    private readonly PixelHeadScene catHead = new();
    private KeyboardSubscription headSubscription;
    private double lastHeadTime;
    private readonly Forms.ContextMenuStrip menu = new();
    private readonly System.Windows.Threading.DispatcherTimer statusTimer;
    private VisualizationView view = null!;
    private AudioSubscription audioSubscription = null!;
    private KeyboardSubscription keyboardSubscription = null!;
    private bool rendering, adjusting, disposed, isVisible = true, suspended;
    private bool powerSuspended, sessionSuspended;
    private double lastTime;
    private TimeSpan lastRender = TimeSpan.MinValue;
    private Point? dragOrigin;
    private WindowFrame? dragFrame;
    private bool resizing;
    private string lastStatus = "";
    private static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public DesktopHost(Application app)
    {
        this.app = app;
        capture = new LoopbackCapture(audio);
        keyboardCapture = new KeyboardCapture(keyboard);
        headSubscription = keyboard.Subscribe(); lastHeadTime = Now;
        try
        {
            if (File.Exists(Path.Combine(AppContext.BaseDirectory, "miucs_plugins.dll")))
                pluginHost = new PluginHost(audio, keyboard, include: id => !SkinCatalog.IsRetired(id));
            else shellError = "皮肤运行库未找到，请重新解压完整应用。";
        }
        catch (Exception error) when (error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException or System.Text.Json.JsonException)
        { shellError = "皮肤运行库加载失败：" + error.Message; }
        window = new Window
        {
            Title = "Miucs", WindowStyle = WindowStyle.None, AllowsTransparency = true,
            Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
            ShowActivated = false, Topmost = true, Width = 400, Height = 260, Content = root
        };
        adjustment = new Border
        {
            BorderBrush = new SolidColorBrush(Color.FromArgb(180, 90, 130, 170)), BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(15, 90, 130, 170)), Visibility = Visibility.Collapsed,
            Child = new TextBlock { Text = "拖动移动 · 右下角缩放 · 点击小锁完成调整", FontSize = 11, Foreground = Brushes.SlateGray, Margin = new Thickness(6), VerticalAlignment = VerticalAlignment.Bottom }
        };
        status = new TextBlock { FontSize = 11, Margin = new Thickness(6), Foreground = Brushes.SlateGray, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Bottom };
        root.Children.Add(status);
        root.Children.Add(adjustment);
        root.MouseLeftButtonDown += BeginDrag;
        root.MouseMove += Drag;
        root.MouseLeftButtonUp += EndDrag;
        root.LostMouseCapture += (_, _) => { dragOrigin = null; dragFrame = null; };
        window.Closing += (_, e) => { if (!disposed) { e.Cancel = true; SetVisible(false); } };
        window.SizeChanged += (_, _) => { if (view != null) { view.Width = window.Width; view.Height = window.Height; } };
        new WindowInteropHelper(window).EnsureHandle();
        NativeWindow.SetInteractive(window, false);
        SwitchVisualization(preferences.Visualization);
        tray = new Forms.NotifyIcon { Text = "Miucs", ContextMenuStrip = menu };
        trayAnimation = new AnimatedTrayIcon(tray, () => AdvanceCatHead(Now));
        tray.Visible = true;
        UpdateTrayAnimation();
        tray.DoubleClick += (_, _) => Dispatch(ShowSettings);
        menu.Opening += (_, _) => BuildMenu();
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        capture.Start();
        if (preferences.KeyboardEnabled) keyboardCapture.Start();
        statusTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        statusTimer.Tick += (_, _) => UpdateStatus();
        statusTimer.Start();
        window.Show();
        hoverLock = new HoverLockControl(window, () => isVisible && !suspended && !disposed, () => SetAdjusting(!adjusting));
        StartRendering();
        settingsWindow = new SettingsWindow(new SettingsActions
        {
            SelectSkin = SwitchVisualization, SetVisible = SetVisible, TogglePosition = () => SetAdjusting(!adjusting),
            SetScale = value => { SetFrame(CurrentFrame() with { Width = view.BaseWidth * value / 100 }, preserveSize: false); SaveFrame(); SavePreferences(); RefreshSettings(); },
            SetOpacity = value => { preferences.Transparency = (int)Math.Round(100 - value); view.Opacity = 1 - preferences.Transparency / 100d; ApplyColor(); SavePreferences(); RefreshSettings(); },
            SetKeyboardEnabled = value => { preferences.KeyboardEnabled = value; if (value && !suspended) keyboardCapture.Start(); else keyboardCapture.Stop(); ResetCatHead(); SavePreferences(); UpdateStatus(); },
            SetTrayAnimation = value => { preferences.TrayAnimationEnabled = value; UpdateTrayAnimation(); SavePreferences(); RefreshSettings(); },
            ReconnectAudio = () => { if (!suspended) capture.Reconnect(); },
            Rescan = RescanSkins, Reload = () => pluginHost?.ReloadActive(), OpenDirectory = OpenSkinDirectory
        });
        app.MainWindow = settingsWindow;
        ShowSettings();
    }

    internal void ShowSettings() { RefreshSettings(); settingsWindow.Present(); }
    private void RefreshSettings()
    {
        if (settingsWindow == null) return;
        using var subscription = keyboard.Subscribe();
        string keyboardStatus = subscription.Read(Now).State.ToString();
        settingsWindow.UpdateState(new SettingsState(
            pluginHost?.Views.Values.ToArray() ?? Array.Empty<PluginInfo>(), view.Id, isVisible, adjusting,
            window.Width / view.BaseWidth * 100, view.LayoutMinWidth / view.BaseWidth * 100,
            view.LayoutMaxWidth / view.BaseWidth * 100, 100 - preferences.Transparency,
            preferences.KeyboardEnabled, preferences.TrayAnimationEnabled, lastStatus, keyboardStatus,
            string.Join("\n", new[] { shellError, capture.LastError, pluginHost?.Error }.Where(e => !string.IsNullOrEmpty(e)))));
    }
    private void OpenSkinDirectory()
    {
        try { Directory.CreateDirectory(PluginHost.UserDirectory); Process.Start(new ProcessStartInfo(PluginHost.UserDirectory) { UseShellExecute = true }); shellError = ""; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception) { shellError = "无法打开皮肤文件夹：" + e.Message; }
        RefreshSettings();
    }
    private void RescanSkins()
    {
        pluginHost?.Scan();
        if (pluginHost?.Views.ContainsKey(view.Id) != true) SwitchVisualization(preferences.Visualization);
        RefreshSettings();
    }

    private void Dispatch(Action action)
    {
        if (!disposed && !app.Dispatcher.HasShutdownStarted) app.Dispatcher.BeginInvoke(new Action(() => { if (!disposed) action(); }));
    }
    private void SwitchVisualization(string id)
    {
        if (pluginHost?.Views.ContainsKey(id) != true)
            id = pluginHost?.Views.ContainsKey("pixel-keyboard") == true ? "pixel-keyboard" : pluginHost?.Views.Keys.FirstOrDefault() ?? "";
        if (view != null && view.Id == id) return;
        WindowFrame? previous = view == null ? null : CurrentFrame();
        hoverLock?.Reset();
        StopRendering();
        if (view != null) { SaveFrame(); root.Children.Remove(view); view.Dispose(); }
        view = id.Length > 0 && pluginHost != null ? new PluginView(pluginHost, id) : new EmptyPluginView();
        if (id.Length > 0) preferences.Visualization = id;
        ApplyColor(); view.Opacity = 1 - preferences.Transparency / 100d;
        root.Children.Insert(0, view);
        if (previous == null)
            SetFrame(preferences.RestoreSkinFrame(id, new WindowFrame(80, 80, view.BaseWidth, view.BaseHeight)));
        else { view.Width = window.Width; view.Height = window.Height; }
        SaveFrame(); SavePreferences(); RefreshSettings();
        if (isVisible) StartRendering();
    }

    private WindowFrame CurrentFrame() => new(window.Left, window.Top, window.Width, window.Height);
    private void SetFrame(WindowFrame requested, bool preserveSize = true)
    {
        // Move first so MonitorFromWindow identifies the saved monitor; disconnected displays fall back to nearest.
        if (requested.IsValid) { window.Left = requested.X; window.Top = requested.Y; }
        var area = NativeWindow.WorkArea(window);
        var frame = preserveSize ? WindowPlacement.FitPreservingSize(requested, area) : WindowPlacement.Fit(requested, area, view.BaseWidth / view.BaseHeight, view.LayoutMinWidth, view.LayoutMaxWidth);
        window.Left = frame.X; window.Top = frame.Y; window.Width = frame.Width; window.Height = frame.Height;
        view.Width = frame.Width; view.Height = frame.Height;
    }
    private void SaveFrame() { if (view != null && view.Id.Length>0 && CurrentFrame().IsValid) preferences.SkinFrame = CurrentFrame(); }
    private void SavePreferences()
    {
        if (!preferences.Save(Preferences.DefaultPath) && tray != null)
            tray.ShowBalloonTip(3000, "Miucs", "无法保存偏好；当前会话仍可使用。请检查本地应用数据目录权限。", Forms.ToolTipIcon.Warning);
    }
    private void ApplyColor()
    {
        var p = Preferences.Palette[preferences.Color];
        view.ApplyAppearance(Color.FromRgb(p.R, p.G, p.B));
        pluginHost?.Appearance($"#{p.R:X2}{p.G:X2}{p.B:X2}",1-preferences.Transparency/100d);
    }
    private void StartRendering()
    {
        if (rendering || !isVisible || suspended || disposed) return;
        audioSubscription = audio.Subscribe(); keyboardSubscription = keyboard.Subscribe();
        lastTime = Now; lastRender = TimeSpan.MinValue;
        view.Activate();
        CompositionTarget.Rendering += Render;
        rendering = true;
    }
    private void StopRendering()
    {
        if (!rendering) return;
        CompositionTarget.Rendering -= Render; rendering = false;
        audioSubscription.Dispose(); keyboardSubscription.Dispose();
        view.Deactivate();
    }
    private void Render(object? sender, EventArgs args)
    {
        if (args is RenderingEventArgs renderingArgs)
        {
            if (renderingArgs.RenderingTime == lastRender) return;
            lastRender = renderingArgs.RenderingTime;
        }
        double now = Now;
        double dt = Math.Max(0, now - lastTime); lastTime = now;
        var keys = keyboardSubscription.Read(now);
        var sound = audioSubscription.Read(now);
        if (pluginHost == null) AdvanceCatHead(now);
        view.Update(sound, keys, dt);
    }
    private double AdvanceCatHead(double now)
    {
        if (!suspended && !disposed && now > lastHeadTime)
        {
            catHead.Update(headSubscription.Read(now), now - lastHeadTime);
            lastHeadTime = now;
        }
        return catHead.Angle;
    }
    private void ResetCatHead()
    {
        headSubscription.Dispose(); headSubscription = keyboard.Subscribe();
        catHead.Reset(); lastHeadTime = Now;
    }
    private void UpdateTrayAnimation()
    {
        bool enabled=preferences.TrayAnimationEnabled && SystemParameters.ClientAreaAnimation && !suspended && !disposed;
        trayAnimation.SetRunning(enabled);
    }
    private void OnSystemParametersChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    { if (e.PropertyName == nameof(SystemParameters.ClientAreaAnimation)) Dispatch(UpdateTrayAnimation); }
    private void SetVisible(bool value)
    {
        if (isVisible == value) return;
        if (!value) SetAdjusting(false);
        isVisible = value;
        hoverLock?.Reset();
        if (value) { SetFrame(CurrentFrame()); window.Show(); StartRendering(); }
        else { StopRendering(); SaveFrame(); window.Hide(); SavePreferences(); }
        RefreshSettings();
    }
    private void SetAdjusting(bool value)
    {
        adjusting = value;
        hoverLock?.SetLocked(!value);
        adjustment.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        NativeWindow.SetInteractive(window, value);
        if (value) SetVisible(true);
        else { root.ReleaseMouseCapture(); SaveFrame(); SavePreferences(); }
        RefreshSettings();
    }
    private void BeginDrag(object sender, MouseButtonEventArgs e)
    {
        if (!adjusting) return;
        var p = e.GetPosition(root);
        resizing = p.X >= window.Width - 28 && p.Y >= window.Height - 28;
        dragOrigin = root.PointToScreen(p); dragFrame = CurrentFrame(); root.CaptureMouse(); e.Handled = true;
    }
    private void Drag(object sender, MouseEventArgs e)
    {
        if (!adjusting || dragOrigin == null || dragFrame == null) return;
        var p = root.PointToScreen(e.GetPosition(root));
        var dpi = VisualTreeHelper.GetDpi(window);
        double dx = (p.X - dragOrigin.Value.X) / dpi.DpiScaleX, dy = (p.Y - dragOrigin.Value.Y) / dpi.DpiScaleY;
        if (resizing) SetFrame(dragFrame with { Width = Math.Max(1, dragFrame.Width + dx) }, preserveSize: false);
        else { window.Left = dragFrame.X + dx; window.Top = dragFrame.Y + dy; }
    }
    private void EndDrag(object sender, MouseButtonEventArgs e)
    {
        if (dragOrigin == null) return;
        root.ReleaseMouseCapture(); SetFrame(CurrentFrame()); SaveFrame(); SavePreferences(); RefreshSettings();
    }
    private void BuildMenu()
    {
        while (menu.Items.Count > 0) { var old = menu.Items[0]; menu.Items.RemoveAt(0); old.Dispose(); }
        Add(menu.Items, "打开设置…", ShowSettings);
        Add(menu.Items, isVisible ? "隐藏皮肤" : "显示皮肤", () => SetVisible(!isVisible));
        Add(menu.Items, adjusting ? "完成调整" : "调整位置与大小…", () => SetAdjusting(!adjusting));
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu.Items, "退出 Miucs", () => { Dispose(); app.Shutdown(); });
    }

    private void Add(Forms.ToolStripItemCollection items, string text, Action action, bool check = false)
    {
        var item = new Forms.ToolStripMenuItem(text) { Checked = check };
        item.Click += (_, _) => Dispatch(action); items.Add(item);
    }
    private void UpdateStatus()
    {
        using var subscription = audio.Subscribe();
        var input = subscription.Read(Now);
        lastStatus = input.State switch
        {
            AudioState.Running => input.Frame == null ? "等待系统声音" : "音频已连接",
            AudioState.Connecting => "正在连接音频", AudioState.Recovering => "正在恢复音频",
            AudioState.PermissionRequired => "音频访问受限", AudioState.Suspended => "已暂停", _ => "音频未连接"
        };
        if (pluginHost?.Error.Length > 0) lastStatus = "插件：" + pluginHost.Error;
        status.Text = pluginHost?.Error.Length > 0 ? lastStatus : input.State == AudioState.Running && input.Frame != null ? "" : lastStatus;
        string tooltip = "Miucs · " + lastStatus;
        tray.Text = tooltip[..Math.Min(63, tooltip.Length)];
        RefreshSettings();
    }
    private void Suspend()
    {
        if (suspended) return;
        SetAdjusting(false);
        hoverLock.Reset();
        suspended = true; pluginHost?.Suspend(true); StopRendering(); capture.Suspend(); keyboardCapture.Suspend();
        ResetCatHead(); UpdateTrayAnimation();
    }
    private void Resume()
    {
        if (!suspended) return;
        suspended = false; pluginHost?.Suspend(false); capture.Resume();
        if (preferences.KeyboardEnabled) keyboardCapture.Resume();
        ResetCatHead(); UpdateTrayAnimation();
        StartRendering();
    }
    private void UpdateSuspension() { if (powerSuspended || sessionSuspended) Suspend(); else Resume(); }
    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) Dispatch(() => { powerSuspended = true; UpdateSuspension(); });
        else if (e.Mode == PowerModes.Resume) Dispatch(() => { powerSuspended = false; UpdateSuspension(); });
    }
    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff or SessionSwitchReason.RemoteDisconnect or SessionSwitchReason.ConsoleDisconnect) Dispatch(() => { sessionSuspended = true; UpdateSuspension(); });
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon or SessionSwitchReason.RemoteConnect or SessionSwitchReason.ConsoleConnect) Dispatch(() => { sessionSuspended = false; UpdateSuspension(); });
    }
    private void OnDisplayChanged(object? sender, EventArgs e) => Dispatch(() => { trayAnimation.RefreshSize(); hoverLock.Reset(); SetAdjusting(false); SetFrame(CurrentFrame()); SaveFrame(); SavePreferences(); });
    public void Dispose()
    {
        if (disposed) return;
        SaveFrame(); SavePreferences(); StopRendering(); disposed = true;
        statusTimer?.Stop();
        hoverLock.Dispose();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
        SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
        headSubscription.Dispose();
        capture.Dispose(); keyboardCapture.Dispose(); view.Dispose();
        settingsWindow?.CloseForExit();
        tray.Visible = false; pluginHost?.Dispose(); trayAnimation.Dispose(); tray.Dispose(); menu.Dispose(); window.Close();
    }
}
