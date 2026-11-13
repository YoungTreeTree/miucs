# 将 Miucs 嵌入 macOS 应用

Miucs 仓库同时提供独立桌面应用和 `MiucsCore` Swift Package。核心库静态链接到宿主进程，包含键盘监听、系统音频分析、输入契约、七套皮肤资源、板端皮肤打包与会话恢复。它不依赖 Skia、`PluginHost`、菜单栏图标或 `miucs-plugin-worker`。最低 macOS 14、Swift 6；Windows 继续使用现有 C# 模块。

## 仓库与资源

开发时保持两个仓库并列，在宿主 Package.swift 中引用：

```swift
dependencies: [.package(path: "../miucs")]
// 对应宿主 target：
dependencies: [.product(name: "MiucsCore", package: "miucs")]
```

发布构建可以改成仓库 URL 并锁定 tag 或提交。宿主不复制修改 Miucs 源码；库、皮肤和测试由本仓库维护。

`swift build -c release --product MiucsCore` 生成静态库和 `Miucs_MiucsCore.bundle`。自行组装 .app 时，把资源包原样复制到 `Contents/Resources/`。Xcode 的包依赖由 Xcode 处理资源。`PetCatalog.scan()` 读取内置皮肤和 `~/Library/Application Support/Miucs/Plugins`，也可注入目录。目录扫描和静态预览不运行 Lua。

## 输入与生命周期

```swift
import MiucsCore

@MainActor
final class Companion {
    let audio = AudioEngine()
    let keyboard = KeyboardEngine()
    let pet = NativePetSession()

    func start(skin: PetSkin, transport: any NativePetTransport) async {
        pet.start(skin: skin, audio: audio.channel, keyboard: keyboard.channel, transport: transport)
        await keyboard.start(requestAccess: false)
        // 宿主音频开关启用时，再调用 await audio.start()。
    }

    func stop() async {
        pet.stop()
        audio.stop()
        keyboard.stop()
        await pet.waitUntilStopped()
    }
}
```

键盘与音频权限归宿主应用，应在宿主设置中提供授权入口、开关和状态。宿主提供 `NSAudioCaptureUsageDescription` / `NSScreenCaptureUsageDescription`，使用稳定签名以保持更新后的授权；Miucs 的权限不会直接授予其他 bundle identifier。

通道订阅各有独立游标。换肤不重启输入采集；禁用组件或设备断开时宿主可以暂停采集。数据只有物理按键身份和音频特征，不包含输入文字、录音或屏幕图像。关闭或释放会话都会取消订阅、重试、唤醒任务并关闭传输。

## USB 所有权

宿主实现 `NativePetTransport`，负责设备发现、串口独占与逻辑通道。也可使用 `SerialPetTransport(open:)`：闭包返回已配置为非阻塞的 CDC 描述符或进程内 socket pair，返回后所有权移交给库，库负责关闭。不能返回仍被另一对象读取的同一个描述符。`HardwareIO.wait` 使用 Darwin `select(2)` 同时等待串口和 socket；不要用不支持设备文件的 `poll(2)` 等待串口可读写。

桌屿持有 CH343 物理连接，在布局和桌宠通道之间公平切换。内嵌模式直接使用进程内通道，无需另一个 Miucs 应用。独立 Miucs 的 `HardwarePort` 继续在应用层发现设备。宿主应在硬件连接期间保持必要的后台活动，避免隐藏窗口后 App Nap 延误设备回执；不要因此阻止系统正常休眠。

会话支持 DESKISLE_PET v1–v3，按设备上限与 32 KiB 中的较小值分块上传，并提供同步进度。v3 先按长度和 CRC 恢复实例，不存在才重传。按键变化立即触发发送；活跃音频合并到约 30 Hz；空闲只有保活。v2/v3 输入有序连续写入，并检查已经到达的 ACK；上传与恢复命令等待对应回执。

原生会话不会回退到 Mac 图像渲染。不支持的皮肤或固件返回状态，由宿主提示。独立桌面应用保留 Lua/Skia worker 和旧 JPEG 屏幕适配。

## 验证

```sh
swift test
zsh scripts/test-contracts.sh
zsh scripts/test-keyboard.sh
zsh scripts/test-audio-recovery.sh
zsh scripts/test-hardware.sh
zsh scripts/test-settings.sh
zsh build.sh
```

包测试使用合成输入与模拟传输，不申请系统权限。覆盖七套真实皮肤打包、目录边界、输入限额、按键顺序、快速换肤时的通道所有权、板端实例丢失恢复和会话释放。真实设备联调在宿主应用身份下完成授权并核对设备回执。
