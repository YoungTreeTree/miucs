# Miucs for Windows · 首个原生实现（实机验收待完成）

.NET 8 / WPF + Win32 + WASAPI，面向 Windows 10/11 x64；运行时不依赖 macOS、Python、云音频服务或外部模型；Lua/Skia 运行库随应用提供。ARM64 可从源码交叉发布，但当前交付与检查以 x64 为主。

**实现与验证不是一回事：** 核心测试可跨平台运行；原生设置、鼠标命中、GIF 与插件绘制测试由 Windows CI 执行；真实音频设备和多屏环境仍需实机验收。因此不是已验证稳定版。真实 WASAPI、全局键盘、透明穿透、多屏 DPI、休眠恢复仍须按 [验收表](../../docs/windows-acceptance.md) 在 Windows 上验证。画面由共享 Lua/Skia 插件绘制，WPF 负责窗口和菜单。

## 直接运行

解压 `Miucs-windows-x64.zip`，保留整个目录，运行 `Miucs.exe`。自包含版本无需单独安装 .NET，也不需要管理员权限。退出后可直接删除目录。无安装器、无签名、无开机自启、无注册表持久化；未签名的新程序可能显示 Windows 信任提示，应先核对来源及 SHA-256，不要关闭系统安全设置。

启动后直接打开设置，在任务栏和通知区域都能找到 Miucs。首次默认选择奶牛猫；其他皮肤在卡片中选择。系统音频来自当前默认多媒体播放设备，不使用麦克风。

- **皮肤**：图片 / GIF 卡片、重新扫描、重新加载和打开皮肤文件夹。图片、文字和留白都属于同一个按钮，有悬浮、按下与键盘焦点反馈。
- **外观与位置**：大小、不透明度和桌面调整。切换只换皮肤，当前位置与大小保持不变；首次升级从当前皮肤迁移，重启恢复共享记录。
- **声音与键盘**：状态、音频重连、键盘响应和托盘动画。键盘响应默认关闭，需要主动启用；只处理短暂物理键位，不读取输入文字。
- **程序入口**：关闭设置时最小化到任务栏，皮肤继续运行；点击任务栏、双击托盘图标或再次运行应用会恢复设置，不产生第二个实例。
- **托盘快捷操作**：打开设置、显示 / 隐藏皮肤、调整位置与大小、退出。
- **桌面调整**：悬停皮肤 3 秒点击小锁，拖动移动、右下角等比缩放，完成后恢复穿透。显示 / 隐藏皮肤独立于设置窗口。

偏好保存在 `%LOCALAPPDATA%\Miucs\preferences.v1.json`，共享窗口位置为 `SkinFrame`，旧的 `Frames` 用于首次迁移。皮肤放在 `%LOCALAPPDATA%\Miucs\Plugins`；升级应用不会覆盖这些用户目录。预览只显示图片，不启动第二个插件。缺失运行库时设置仍可打开并显示错误。

托盘保留原猫头的颜色，并尽量铺满图标槽，不随画面透明度淡出；浅色描边适配深浅任务栏。25 个角度的 ICO 预先缓存，包含 16～64px 多种尺寸；更新最多每秒 16 次，仅在角度档位改变时通知系统，不逐帧创建图标句柄。退出释放全部图标与计时器。

## 构建与测试

安装官方 **.NET 8 SDK**、Python 3.10+、CMake 3.24+ 和 Visual Studio C++ 工具链；首次 restore 需要访问 NuGet 获取微软 Windows 目标框架/运行时包。

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

Linux/macOS 可交叉编译外壳以检查 C# 代码；完整分发包须在 Windows 执行上述构建脚本，打包 Lua/Skia 运行库：

```sh
dotnet publish apps/windows/Miucs.Windows.csproj -c Release -r win-x64 --self-contained true -o dist/windows/win-x64
```

`.github/workflows/windows.yml` 提供 Linux 核心测试和 Windows 构建/原生离屏检查。每次 PR 会运行构建和原生测试，结果以该 PR 的检查记录为准。Windows CI 的离屏检查也不等于真实声卡/桌面验收。

## 结构与职责

- `modules/audio/platforms/windows/Core/`：纯 C# FFT、特征/混音主旋律/节拍和独立订阅通道；以 Swift 当前算法为移植依据，合成测试与独立 NumPy 对照验证。
- `modules/audio/platforms/windows/Capture/`：WASAPI COM、PCM 格式解码、设备探测/退避恢复；不依赖可视化。
- `modules/keyboard/platforms/windows/Core/`：物理键短事件/按住状态通道；`KeyboardCapture.cs` 负责只读全局钩子及安全桌面检查。
- `modules/plugins/platforms/windows/`：插件宿主和 Skia 展示；`plugins/` 保存共享 Lua 场景。
- `apps/windows/`：入口、透明窗口、通知区菜单、同步刷新、偏好和输入组合。

核心音频/键盘通道分别保留 64/128 个、250ms 内的短事件，使用独立订阅游标；重连换代并拒绝旧回调。线程与 UI 不逐帧传递 JSON。音乐和键盘独立工作，静音仍可触发星爆。显示刷新使用 DWM 帧等待，长帧按完整时间淘汰历史。 主窗口改为 DWM 硬件合成透明像素，不再每帧用分层窗口做软件上传。插件的 GPU 画面跟随显示器刷新率，只有 CPU 回退仍限制为 30 FPS。

## 已知边界

1. 系统播放格式支持 PCM16/24/32 或 Float32（含 WAVEFORMATEXTENSIBLE）。环绕声按声道掩码混成分析用的立体声。回环使用设备最小缓冲。托盘显示错误类别。
2. 回环受 Windows 音频系统限制，独占模式、受保护内容或特殊驱动不保证可捕获；不绕过保护。
3. 混音主旋律是启发式估计，不是歌声分离或完整记谱；复杂混音仍可能选错音。
4. 首版没有自动启动、自动升级、安装器或代码签名。只有用户主动运行时工作。
5. 真实多屏不同 DPI、通知区域恢复、驱动挂起和资源占用需要目标机器验收；不能根据交叉构建宣称全部通过。

API 依据：[微软 WASAPI 回环](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)、[WPF 窗口](https://learn.microsoft.com/dotnet/desktop/wpf/windows/)。

所有构建必须包含 Lua/Skia 插件运行库和插件目录，不提供省略插件的构建选项。
