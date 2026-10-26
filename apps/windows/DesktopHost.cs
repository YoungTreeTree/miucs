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
    private readonly HoverLockControl hoverLock;
    private readonly Grid root = new();
    private readonly Border adjustment;
    private readonly TextBlock status;
    private readonly Forms.NotifyIcon tray;
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
        tray = new Forms.NotifyIcon { Text = "Miucs", Icon = System.Drawing.SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => Dispatch(() => SetVisible(!isVisible));
        menu.Opening += (_, _) => BuildMenu();
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.DisplaySettingsChanged += OnDisplayChanged;
        capture.Start();
        if (preferences.KeyboardEnabled) keyboardCapture.Start();
        statusTimer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        statusTimer.Tick += (_, _) => UpdateStatus();
        statusTimer.Start();
        window.Show();
        hoverLock = new HoverLockControl(window, () => isVisible && !suspended && !disposed, () => SetAdjusting(!adjusting));
        StartRendering();
    }

    private void Dispatch(Action action)
    {
        if (!disposed && !app.Dispatcher.HasShutdownStarted) app.Dispatcher.BeginInvoke(new Action(() => { if (!disposed) action(); }));
    }
    private void SwitchVisualization(string id)
    {
        if (view != null && view.Id == id) return;
        if (id != "pencil-flight" && id != "staff-note" && id != "pixel-keyboard") return;
        WindowFrame? previous = view == null ? null : CurrentFrame();
        hoverLock?.Reset();
        StopRendering();
        if (view != null)
        {
            SaveFrame(); root.Children.Remove(view); view.Dispose();
        }
        view = id switch { "staff-note" => new StaffNoteView(), "pixel-keyboard" => new PixelKeyboardView(), _ => new PencilFlightView() };
        preferences.Visualization = id;
        ApplyColor();
        root.Children.Insert(0, view);
        var requested = preferences.Frames.TryGetValue(id, out var saved) ? saved :
            new WindowFrame(previous?.X ?? 80, previous?.Y ?? 80, view.BaseWidth, view.BaseHeight);
        SetFrame(requested);
        SavePreferences();
        if (isVisible) StartRendering();
    }
    private WindowFrame CurrentFrame() => new(window.Left, window.Top, window.Width, window.Height);
    private void SetFrame(WindowFrame requested)
    {
        // Move first so MonitorFromWindow identifies the saved monitor; disconnected displays fall back to nearest.
        if (requested.IsValid) { window.Left = requested.X; window.Top = requested.Y; }
        var frame = WindowPlacement.Fit(requested, NativeWindow.WorkArea(window), view.BaseWidth / view.BaseHeight, view.LayoutMinWidth, view.LayoutMaxWidth);
        window.Left = frame.X; window.Top = frame.Y; window.Width = frame.Width; window.Height = frame.Height;
        view.Width = frame.Width; view.Height = frame.Height;
    }
    private void SaveFrame() { if (view != null && CurrentFrame().IsValid) preferences.Frames[view.Id] = CurrentFrame(); }
    private void SavePreferences()
    {
        if (!preferences.Save(Preferences.DefaultPath) && tray != null)
            tray.ShowBalloonTip(3000, "Miucs", "无法保存偏好；当前会话仍可使用。请检查本地应用数据目录权限。", Forms.ToolTipIcon.Warning);
    }
    private void ApplyColor()
    {
        var p = Preferences.Palette[preferences.Color];
        view.ApplyAppearance(Color.FromRgb(p.R, p.G, p.B));
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
        view.Update(sound, keys, dt);
    }
    private void SetVisible(bool value)
    {
        if (isVisible == value) return;
        if (!value) SetAdjusting(false);
        isVisible = value;
        hoverLock?.Reset();
        if (value) { SetFrame(CurrentFrame()); window.Show(); StartRendering(); }
        else { StopRendering(); SaveFrame(); window.Hide(); SavePreferences(); }
    }
    private void SetAdjusting(bool value)
    {
        adjusting = value;
        hoverLock?.SetLocked(!value);
        adjustment.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        NativeWindow.SetInteractive(window, value);
        if (value) SetVisible(true);
        else { root.ReleaseMouseCapture(); SaveFrame(); SavePreferences(); }
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
        if (resizing) SetFrame(dragFrame with { Width = Math.Max(1, dragFrame.Width + dx) });
        else { window.Left = dragFrame.X + dx; window.Top = dragFrame.Y + dy; }
    }
    private void EndDrag(object sender, MouseButtonEventArgs e)
    {
        if (dragOrigin == null) return;
        root.ReleaseMouseCapture(); SetFrame(CurrentFrame()); SaveFrame(); SavePreferences();
    }
    private void BuildMenu()
    {
        while (menu.Items.Count > 0) { var old = menu.Items[0]; menu.Items.RemoveAt(0); old.Dispose(); }
        menu.Items.Add(new Forms.ToolStripMenuItem("Miucs · " + lastStatus) { Enabled = false });
        if (capture.LastError is string error) menu.Items.Add(new Forms.ToolStripMenuItem(error) { Enabled = false });
        using (var keys = keyboard.Subscribe())
            menu.Items.Add(new Forms.ToolStripMenuItem("键盘状态：" + keys.Read(Now).State) { Enabled = false });
        Add(menu.Items, isVisible ? "隐藏画面" : "显示画面", () => SetVisible(!isVisible));
        var modes = new Forms.ToolStripMenuItem("可视化"); menu.Items.Add(modes);
        Add(modes.DropDownItems, "铅笔飞鸟", () => SwitchVisualization("pencil-flight"), view.Id == "pencil-flight");
        Add(modes.DropDownItems, "五线谱音符", () => SwitchVisualization("staff-note"), view.Id == "staff-note");
        Add(modes.DropDownItems, "像素音乐键盘", () => SwitchVisualization("pixel-keyboard"), view.Id == "pixel-keyboard");
        var sizes = new Forms.ToolStripMenuItem("画面大小"); menu.Items.Add(sizes);
        foreach (int percent in new[] { 10, 80, 100, 125, 150, 200 })
            Add(sizes.DropDownItems, $"{percent}%", () => { SetFrame(CurrentFrame() with { Width = view.BaseWidth * percent / 100d }); SaveFrame(); SavePreferences(); });
        var colors = new Forms.ToolStripMenuItem("线条颜色"); menu.Items.Add(colors);
        foreach (var entry in Preferences.Palette)
            Add(colors.DropDownItems, entry.Value.Name, () => { preferences.Color = entry.Key; ApplyColor(); SavePreferences(); }, preferences.Color == entry.Key);
        Add(menu.Items, adjusting ? "完成调整（恢复鼠标穿透）" : "调整位置与大小…", () => SetAdjusting(!adjusting));
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu.Items, "重新连接音频", () => { if (!suspended) capture.Reconnect(); });
        Add(menu.Items, "键盘输入 · 星爆 / 猫爪", () =>
        {
            preferences.KeyboardEnabled = !preferences.KeyboardEnabled;
            if (preferences.KeyboardEnabled && !suspended) keyboardCapture.Start(); else keyboardCapture.Stop();
            SavePreferences();
        }, preferences.KeyboardEnabled);
        menu.Items.Add(new Forms.ToolStripSeparator());
        Add(menu.Items, "退出", () => { Dispose(); app.Shutdown(); });
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
        status.Text = input.State == AudioState.Running && input.Frame != null ? "" : lastStatus;
        tray.Text = "Miucs · " + lastStatus;
    }
    private void Suspend()
    {
        if (suspended) return;
        SetAdjusting(false);
        hoverLock.Reset();
        suspended = true; StopRendering(); capture.Suspend(); keyboardCapture.Suspend();
    }
    private void Resume()
    {
        if (!suspended) return;
        suspended = false; capture.Resume();
        if (preferences.KeyboardEnabled) keyboardCapture.Resume();
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
    private void OnDisplayChanged(object? sender, EventArgs e) => Dispatch(() => { hoverLock.Reset(); SetAdjusting(false); SetFrame(CurrentFrame()); SaveFrame(); SavePreferences(); });
    public void Dispose()
    {
        if (disposed) return;
        SaveFrame(); SavePreferences(); StopRendering(); disposed = true;
        statusTimer?.Stop();
        hoverLock.Dispose();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.DisplaySettingsChanged -= OnDisplayChanged;
        capture.Dispose(); keyboardCapture.Dispose(); view.Dispose();
        tray.Visible = false; tray.Dispose(); menu.Dispose(); window.Close();
    }
}
