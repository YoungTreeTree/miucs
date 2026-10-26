# 键盘输入契约 v1

键盘和音频是同时运行的独立生产者，各自拥有权限、状态、代次和订阅游标。输入值类型在 `modules/keyboard/core/`，macOS 采集与恢复在 `modules/keyboard/platforms/macos/`。五线谱将物理按键映射为星爆，飞鸟仍使用键盘入口的默认空实现。

## 快照与事件

`KeyboardFeatureSource.subscribe()` 创建独立的 `KeyboardSubscription`，每次 `read()` 返回一个 `KeyboardInput`：

| 字段 | 语义 |
| --- | --- |
| `version` | 当前为 1 |
| `sessionID` | 采集代次；停止、权限丢失、安全输入、休眠和重连都会更新 |
| `sequence` | 本代次最后接收的事件序号，从 1 开始；没有事件时为 0 |
| `state` | `stopped`、`connecting`、`running`、`permissionRequired`、`suspended`、`secureInput`、`recovering` |
| `sampledAt` | 本次读取的主机单调时间，单位秒 |
| `modifiers` | 当前修饰键集合：Shift、Control、Option、Command、Caps Lock、Fn；通用位分别为 0～5 |
| `heldKeys` | 已观察到按下、尚未松开的普通按键，按 `keyCode` 排序；`duration` 是已按住的秒数 |
| `pressesPerSecond` | 最近 1 秒内普通按键的真实按下次数；不计长按连发、重复 down 或修饰键；上限 256 |
| `idleDuration` | 距离最后一次事件的秒数；本代次未收到事件时为 `nil` |
| `events` | 此订阅者尚未读取且未过期的有序短事件 |
| `droppedEventCount` | 此订阅者本次因容量或过期丢失的未读事件数，下次不会重复计数 |

事件携带 `sequence`、`receivedAt`、`kind`、`keyCode`、`modifiers`、可选的 `heldDuration` 和 `modifierIsPressed`。事件种类为 `pressed`、`released`、`repeated`、`modifiersChanged`。普通松开或连发的 `heldDuration` 只有在同代次观察到按下时才有值；中途开始监听不会编造按住起点。新增的可选字段兼容缺少该字段的 v1 数据。

`keyCode` 是 UInt16 平台物理键标识；macOS 为虚拟键码，不是 Unicode 或输入法上屏文字。Windows 使用物理 set-1 扫描码，扩展键 OR `0x100`（A=`0x1E`、左 Control=`0x1D`、右 Control=`0x11D`）；不是虚拟键对应的字符，完整 ANSI 映射见 Windows `StaffNoteScene.cs`。修饰键保留 `modifiersChanged` 和聚合标志；`modifierIsPressed` 表示该物理侧的按下/松开，Caps Lock 则表示切换后的锁定状态。macOS 使用设备左右侧标志识别 Shift、Control、Option、Command；只有聚合标志且无法判断左右侧的合成事件返回 `nil`，不能据此猜测一次按下。Fn 使用独立状态位。修饰键仍不进入普通 `heldKeys`、敲击频率或按住时长，Caps Lock 也不当成长按。

所有时间均使用主机单调时钟，不能与音频 PCM 窗口时间直接相减。长按连发仍算活动，因此会更新 `idleDuration`，但不增加敲击频率。

## 容量与生命周期

事件最多保留 **128 个 / 250ms**，只保留最新项；敲击频率历史最多 256 项 / 1 秒。按住状态独立于事件历史，未松开时不会仅因事件过期而消失。每次读取会更新时长、移除过期事件与频率采样，即使没有新输入也能回落到空闲。

订阅者各自维护游标，互不排空事件。新订阅读取当前状态，不补播订阅前的按键。代次变化清空按住键、修饰键、频率和待消费事件；旧采集的迟到回调被拒绝。捕获代码只写内存，不为每个按键创建 UI 任务。

可视化控制器在同一屏幕刷新中先调用 `receive(keyboard:)`，再调用既有音频 `update(input:deltaTime:)`。两路不互斥；任一路未授权也会继续传递另一路。`receive(keyboard:)` 默认空实现，五线谱覆盖它保存当前键盘快照，在统一动画更新中消费。隐藏/切换模块不停止两个生产者，恢复时两路重新订阅，均不补播旧动作。

## macOS 监听

使用会话级 `CGEventTap` 的 `listenOnly` 模式，只订阅 `keyDown`、`keyUp`、`flagsChanged`。原始事件原样返回，不拦截快捷键、不注入按键、不获取输入文字。只使用 macOS「输入监控」权限，首次正常启动请求一次，之后可从菜单「键盘监听」进入授权；后台检查不会重复弹窗。[Apple 关于权限和只读监听的说明](https://developer.apple.com/forums/thread/707680)

监听端口和回调运行在独立线程；权限预检在后台，Carbon 安全输入检查按系统要求在主线程串行执行，每秒一次。事件端口中断会清空本代次并按 1～30 秒退避重试；键盘空闲不会触发重连。休眠、登录会话切出、权限撤销和安全输入分别暂停，恢复条件满足后自动重建。安全输入期间遵循系统限制，不尝试捕获被保护的按键；恢复后从新代次开始。

原始键码、修饰状态和短事件仅在内存使用，不保存按键历史或输入文字。显式诊断只导出事件分类计数、速率最大值、投递延迟最大值及两路运行状态，不导出键码、逐键时间或文本。

## 验证

```sh
zsh scripts/test-keyboard.sh
zsh scripts/test-visualization-host.sh
zsh build.sh
open -n -g "$PWD/dist/Miucs.app" --args --diagnose-inputs --duration 8 --output "$PWD/build/input-diagnostics.json"
```

自动测试使用合成事件和可控权限环境，不修改系统权限、不向前台程序发送按键。真实诊断需先授权输入监控；可在这 8 秒里正常打字、长按和松开，同时播放音频，检查 `simultaneousRunningSamples`、`keyboardEventsByKind` 与 `audioFeatureFrames`。未授权时报告 `permissionRequired`，不能将它当成真实键盘监听已通过。

真实权限验收必须通过 Launch Services（如上面的 `open -n`）启动目标应用。直接执行 `Contents/MacOS/Miucs` 可能沿用终端或开发工具的权限，其 `running` 不能证明桌面启动的 Miucs 已获授权。若系统授权后选择“退出并重新打开”，还应检查实际进程的应用路径：存在多个同标识副本时可能打开“应用程序”里的旧版。更新安装副本后再验证，避免把版本或权限差异误判成动画失效。

本轮自动检查、构建、签名和实机诊断范围见[验证记录](../../docs/validation/keyboard-input-validation.json)。
