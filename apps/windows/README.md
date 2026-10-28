# Miucs for Windows · 首个原生实现（实机验收待完成）

.NET 8 / WPF + Win32 + WASAPI，面向 Windows 10/11 x64；不依赖 macOS、Python、云音频服务、外部模型或第三方运行时包。ARM64 可从源码交叉发布，但当前交付与检查以 x64 为主。

**实现与验证不是一回事：** 本轮在 Linux 云端实现、执行可移植测试并交叉构建 Windows 产物；没有访问用户电脑，也没有 Windows 桌面/声卡可实测。因此不是已验证稳定版。真实 WASAPI、全局键盘、透明穿透、多屏 DPI、休眠恢复仍须按 [验收表](../../docs/windows-acceptance.md) 在 Windows 上验证。WPF 画面保持音乐映射和透明铅笔风格，不承诺与 AppKit 像素级相同。

## 直接运行

解压 `Miucs-windows-x64.zip`，保留整个目录，运行 `Miucs.exe`。自包含版本无需单独安装 .NET，也不需要管理员权限。退出后可直接删除目录。无安装器、无签名、无开机自启、无注册表持久化；未签名的新程序可能显示 Windows 信任提示，应先核对来源及 SHA-256，不要关闭系统安全设置。

启动后在通知区域寻找 Miucs 图标（可能位于折叠区）。默认显示飞鸟，捕获**当前默认多媒体播放设备**的系统混音，不使用麦克风。播放音乐后自动驱动画面。WASAPI 空闲设备可能没有 PCM；此时不伪造静音帧，也不因为没有音乐不断重连。

- **可视化**：铅笔飞鸟 / 五线谱音符 / 像素音乐键盘；切换不重启两路输入。
- **托盘猫摇头**：所有模式统一显示同一只像素猫；与像素键盘浮窗共用猫头角度，开启键盘输入后随打字速度摇头，停下后回正。隐藏画面仍可响应，切换模式不换猫、不重启动作。可从菜单关闭托盘动画；锁屏/休眠或 Windows 关闭界面动画时保持静止。不会因此自动开启键盘监听。
- **画面大小**：10%、80%、100%、125%、150%、200%；拖动缩放同样可以到基准宽度的 10%，并始终保留模块比例。
- **线条颜色**：五种公共笔色，即时更新，不清空轨迹。
- **调整位置与大小**：鼠标停留画面 3 秒后，点击中心偏上的手绘小锁解锁；拖动画面移动、右下角等比缩放，再点小锁恢复穿透。托盘入口仍可用。锁定时仅显示出来的小锁按钮接收点击，画面其余部分仍穿透；锁定时移出画面后重新计时。解锁可拖动时，小锁一直显示。
- **隐藏/显示**：暂停/恢复绘制，恢复时不补播旧事件。
- **重新连接音频**：手动重建采集；设备切换与故障也会后台自动恢复。
- **键盘输入（星爆 / 猫爪）**：默认关闭，需明确从菜单启用；状态显示于托盘菜单。只处理短暂物理扫描码，不读取字符、输入法文本、剪贴板，不写按键日志、不发送网络请求、不拦截快捷键。不能监听安全桌面；锁屏/休眠时暂停。
- **退出**：释放捕获、线程、绘制会话和托盘。

偏好仅保存在 `%LOCALAPPDATA%\Miucs\preferences.v1.json`，包括模式、颜色、键盘开关及各模式独立窗口位置/大小，不包含音频或按键内容。删除此文件可重置偏好。异常/损坏偏好自动回退。

托盘保留原猫头的颜色，不随画面透明度淡出；浅色描边适配深浅任务栏。25 个角度的 ICO 预先缓存，包含 16～64px 多种尺寸；更新最多每秒 16 次，仅在角度档位改变时通知系统，不逐帧创建图标句柄。退出释放全部图标与计时器。

## 构建与测试

安装官方 **.NET 8 SDK**。无需 Visual Studio；首次 restore 需要访问 NuGet 获取微软 Windows 目标框架/运行时包。

```powershell
# 仓库根目录；先跑可移植测试，再生成自包含 x64 目录
./scripts/build-windows.ps1
./dist/windows/win-x64/Miucs.exe

# 可选 ARM64 或依赖预装 .NET 8 Desktop Runtime 的小体积版本
./scripts/build-windows.ps1 -Runtime win-arm64
./scripts/build-windows.ps1 -FrameworkDependent

# 可在 Linux/macOS/Windows 执行的真实核心测试
 dotnet run --project tests/platforms/windows/CoreTests/Miucs.CoreTests.csproj -c Release

# 在 Windows 执行 WPF 原生离屏绘制、透明像素及生命周期检查
# 不启动真实捕获，不更改用户偏好；输出仅合成画面
./dist/windows/win-x64/Miucs.exe --smoke-test build/windows-smoke
```

Linux 交叉发布：

```sh
dotnet publish apps/windows/Miucs.Windows.csproj -c Release -r win-x64 --self-contained true -o dist/windows/win-x64
```

`.github/workflows/windows.yml` 提供 Linux 核心测试和 Windows 构建/原生离屏检查。工作流仅作为源文件交付，本轮**未推送、未触发远程 CI**。Windows CI 的离屏检查也不等于真实声卡/桌面验收。

## 结构与职责

- `modules/audio/platforms/windows/Core/`：纯 C# FFT、特征/混音主旋律/节拍和独立订阅通道；以 Swift 当前算法为移植依据，合成测试与独立 NumPy 对照验证。
- `modules/audio/platforms/windows/Capture/`：WASAPI COM、PCM 格式解码、设备探测/退避恢复；不依赖可视化。
- `modules/keyboard/platforms/windows/Core/`：物理键短事件/按住状态通道；`KeyboardCapture.cs` 负责只读全局钩子及安全桌面检查。
- `modules/visualizations/*/platforms/windows/`：独立纯数据场景与 WPF 绘制。
- `apps/windows/`：入口、透明窗口、通知区菜单、同步刷新、偏好和输入组合。

核心音频/键盘通道分别保留 64/128 个、250ms 内的短事件，使用独立订阅游标；重连换代并拒绝旧回调。线程与 UI 不逐帧传递 JSON。音乐和键盘独立工作，静音仍可触发星爆。显示刷新使用 WPF `CompositionTarget.Rendering`，长帧按完整时间淘汰历史。

## 已知边界

1. 系统播放格式目前支持单/双声道 PCM16/24/32 或 Float32（含 WAVEFORMATEXTENSIBLE）。环绕声设备需在 Windows 播放设置切换到立体声；不偷偷将多声道当作双声道。托盘显示错误类别。
2. 回环受 Windows 音频系统限制，独占模式、受保护内容或特殊驱动不保证可捕获；不绕过保护。
3. 混音主旋律是启发式估计，不是歌声分离或完整记谱；复杂混音仍可能选错音。
4. 首版没有自动启动、自动升级、安装器或代码签名。只有用户主动运行时工作。
5. 真实多屏不同 DPI、通知区域恢复、驱动挂起和资源占用需要目标机器验收；不能根据交叉构建宣称全部通过。

API 依据：[微软 WASAPI 回环](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[WPF 窗口](https://learn.microsoft.com/dotnet/desktop/wpf/windows/)。
