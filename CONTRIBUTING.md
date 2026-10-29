# 参与 Miucs 开发

当前可运行版本是 macOS 原生应用。请先阅读 [架构说明](docs/architecture.md)、[音频契约](contracts/audio-features/README.md) 和 [可视化契约](contracts/visualization/README.md)。Windows 已新增独立 .NET 8/WPF 实现和构建入口；跨平台核心测试/交叉构建与 Windows 实机验收分开记录，后者尚待执行。

## 平台支持

| 平台 | 音频采集 / 恢复 | 分析后端 | 铅笔飞鸟绘制 | 五线谱音符绘制 | 应用外壳 |
| --- | --- | --- | --- | --- | --- |
| macOS 14+ / Apple Silicon | 已实现，含自动恢复 | Swift 分析 + Accelerate FFT | AppKit，共用五种笔色 | AppKit，共用五种笔色 | 已实现 |
| Windows 10/11 x64 | WASAPI 已实现；实机待验 | C# FFT/混音旋律/节拍；合成测试 | WPF 已实现；实机待验 | WPF 已实现；实机待验 | 托盘/透明窗口已实现；实机待验 |

通用核心当前以 Swift 源码实现。语言无关契约与样本为跨平台协作入口，不表示 Windows 已能直接构建这些代码。

## 本地开发

需要 Swift 6 的 Xcode 或 Command Line Tools；首次本地签名需要 OpenSSL 3。`build.sh` 保持稳定应用标识和 `Miucs Dev` 开发签名，产物在忽略的 `dist/`。如使用 Xcode，可用项目现有的 `project.yml` 生成工程。

```sh
zsh build.sh
open dist/Miucs.app
```


只修改模块时优先进入相应 `core/` 或 `platforms/macos/`。`scripts/swift-sources.sh` 通过模块目录通配符定义编译分组；增加目录时也要更新 `project.yml`。应用组合点是 `apps/macos/BuiltInVisualizations.swift`。

离线参考和资源工具需要 Python；应用运行不依赖 Python：

```sh
python3 -m pip install -r tests/requirements.txt
```

## 测试与诊断

以下命令从仓库根目录执行，不改变个人位置或配色偏好。原生窗口与调色盘测试使用独立偏好域。

```sh
zsh scripts/test-contracts.sh       # 依赖边界、Schema、通道与会话切换
zsh scripts/test-keyboard.sh        # 键盘通道、并行输入、权限/休眠/重连和原生事件解码
zsh scripts/test-flight.sh          # 飞鸟规则，含距离/体积/气团
zsh scripts/test-staff-note.sh      # 真实谱位、平滑运动、左右摆动、轨迹和输入生命周期
zsh scripts/test-staff-note-platform.sh # 两种布局、独立偏好、生产绘图和合成静帧
zsh scripts/test-staff-keyboard.sh  # ANSI 布局、并行星爆、长按生命周期、原生图层池和五色缩放
zsh scripts/test-beat-tracker.sh    # 原始 PCM 节拍、半速/倍速、变速、静音和时序
zsh scripts/test-staff-beats.sh     # 拍点轻弧、全部动效并行、生命周期和原生绘制
zsh scripts/test-melody.sh          # 合成独奏/伴奏与响应时序
zsh scripts/test-audio-pipeline.sh  # 分析编排等价与格式切换
zsh scripts/test-audio-recovery.sh  # 采集生命周期、退避与迟到回调
zsh scripts/test-palette.sh         # 颜色存储、真实绘图与调色盘
zsh scripts/test-appearance.sh      # 全局五色、菜单选择、迁移、模块切换和绘图缓存
zsh scripts/test-visualization-host.sh # 原生视图切换、资源释放和窗口兼容
zsh scripts/validate-audio.sh       # 基础音频与独立 NumPy 参考
```

构建后运行窗口验证与预览：

```sh
dist/Miucs.app/Contents/MacOS/Miucs --verify-flight-window --output docs/validation/flight-window-tests.json
dist/Miucs.app/Contents/MacOS/Miucs --render-flight-preview --output build/flight-preview
dist/Miucs.app/Contents/MacOS/Miucs --render-staff-preview --output build/staff-note-preview
dist/Miucs.app/Contents/MacOS/Miucs --diagnose-inputs --duration 8 --output build/input-diagnostics.json
```

`--diagnose-inputs` 同时检查音频和键盘，只导出分类计数和状态。真实桌面权限请用 `open -n -g "$PWD/dist/Miucs.app" --args --diagnose-inputs --duration 8 --output "$PWD/build/input-diagnostics.json"` 验证；直接运行二进制可能继承开发工具权限。键盘需要先授予「输入监控」权限；普通诊断不弹授权框，可显式加 `--request-keyboard-access` 请求权限。诊断期间可正常打字和播放音频，不会保存按键内容。字段与数据范围见[键盘输入契约](contracts/keyboard-input/README.md)。

实际系统回放检查需要已授予系统音频捕获权限，会播放约 12 秒合成低幅度测试音：

```sh
zsh scripts/validate-audio.sh --live
```

其他现有入口保持可用：

```sh
zsh scripts/analyze-audio-file.sh /absolute/input.wav /absolute/features.json
python3 scripts/evaluate-melody.py --help
python3 scripts/benchmark-pop-melody.py --prepare --adc-dataset build/adc2004 --diagnose-vocals
zsh scripts/measure-performance.sh
zsh scripts/measure-performance.sh --cadence
zsh scripts/measure-performance.sh --staff-cadence build/staff-note-cadence.json
zsh scripts/measure-performance.sh --staff-beats build/staff-beat-performance.json
zsh scripts/measure-performance.sh --staff-beats-cadence build/staff-beat-cadence.json 800 15
zsh scripts/measure-performance.sh --staff-keyboard build/staff-keyboard-performance.json
zsh scripts/measure-performance.sh --staff-keyboard-cadence build/staff-keyboard-cadence.json 800 15
zsh scripts/render-demo.sh --desktop
zsh scripts/render-demo.sh --close-up
zsh scripts/render-demo.sh --staff
```

生成的 WAV、逐帧诊断、临时可执行文件在 `build/`；摘要报告在 `docs/validation/`。合成 GIF 使用模拟桌面或纯纸色背景，不能将真实桌面、播放内容、路径或账号信息放入公开示例。`--staff` 通过生成的 PCM、预设物理按键、生产分析器/键盘通道和五线谱原生图层导出并行动画；不会向 macOS 注入按键。编码器验证帧数、时长、逐帧像素和元数据，检查图在 `build/demo-export/review/`。`--staff-keyboard` 测量每秒 20 次按键和 112 颗星的模拟更新与图层提交，目标合计 p95 < 2ms，不包含 WindowServer/GPU。cadence 命令短暂显示合成测试窗口并记录真实刷新间隔，需要解锁桌面并保持显示器唤醒；显示休眠期间系统会暂停同步回调。

## 新增可视化

新增可视化优先从 [Lua 插件开发指南](docs/plugin-development.md) 开始：复制模板、编写场景和动画，再安装到用户目录。插件模式需要使用带运行库的构建并显式开启；无需改动下面的原生模块注册代码。

### 原生模块（编译进应用）

1. 新建 `modules/visualizations/<stable-id>/core/`，实现 `VisualizationSession` 与自己的场景状态；声明稳定 ID、名称和 `VisualizationLayout`（基准宽高、最小/最大宽度）。布局默认值保持飞鸟 400 × 260。
2. 消费连续特征、独立起音事件和区间峰值；按代次/序号去重并处理静音、失联、缺失旋律。数据单位以契约为准，映射与平滑属于本模块。
   键盘快照通过 `receive(keyboard:)` 在同一帧的音频更新之前送达；需要键盘效果的模块覆盖该默认空实现，并在统一动画更新中消费。键盘和音频同时运行，不能将输入源实现成二选一。
3. 在 `platforms/macos/` 实现 `MacVisualizationSession`，提供原生视图与 `applyAppearance(_:)`，使用通用 `VisualizationAppearance.ink` 绘制，保持本模块的线宽和透明度。颜色由外壳统一保存、在激活前应用；模块不另存颜色。停用/释放应幂等，关闭设置窗口并取消自身订阅。原生 UI 类型不能进入通用 API。
4. 在 `BuiltInVisualizations.registry()` 添加工厂注册；核对编译分组并更新 Xcode 源目录。菜单、比例、预设缩放和每个模块的位置大小保存均由外壳读取描述符，无需修改音频分析或采集代码。
5. 在 `tests/visualizations/` 添加合成数据驱动的规则测试，在 `tests/platforms/macos/` 添加需要原生环境的测试；运行契约与原生切换测试。不要把测试用第二模块注册进正式应用。

上述步骤用于保留的原生绘制路径；运行时扩展使用 Lua 插件，不支持第三方原生二进制扩展。`staff-note` 是原生模块接入的完整例子：没有修改音频算法或 JSON 数据契约。模块切换应先暂停绘制、保存旧位置，恢复新模块视口后再激活；隐藏恢复和格式变化不应补播旧动作或轨迹。

## Windows 接入

分别从 [音频适配](modules/audio/platforms/windows/README.md)、[飞鸟绘制](modules/visualizations/pencil-flight/platforms/windows/README.md)、[五线谱绘制](modules/visualizations/staff-note/platforms/windows/README.md) 和 [应用外壳](apps/windows/README.md) 开始。先通过 Schema 与合成样本验证时间、单位、缺失值、事件容量和重连隔离，再做平台采集/恢复、绘制与窗口测试。

Windows 使用 .NET 8/C# 与 WPF，不引入 macOS 目录依赖。`scripts/build-windows.ps1` 先执行可移植核心测试再发布；Linux 也可运行 `scripts/test-windows.sh` 进行测试及交叉构建。新增 `.github/workflows/windows.yml` 包含 Windows 离屏检查；工作流未在本轮远程运行。真实平台验收见 `docs/windows-acceptance.md`，通过前不宣称完整稳定支持。


混音主旋律是唯一运行路径。修改时运行 `test-melody.sh`、`test-audio-pipeline.sh`、`test-audio-recovery.sh` 及五线谱回归；识别质量使用 `python3 scripts/benchmark-pop-melody.py --output build/current-mixture-benchmark.json`，需要已准备的本地音频样本。首次准备命令见上方歌曲基准。此前人声分离对照仅保留历史报告，可从提交 `757e7e3` 恢复相应实验代码；当前构建不下载或打包 SDK/模型。验证入口见[验证索引](docs/validation/README.md)。

## 悬浮锁回归

双端悬浮 3 秒的小锁入口与菜单共用调整状态，设计与实机检查见 [悬浮锁说明](docs/hover-lock.md)。Windows 核心测试包含悬浮等待状态；macOS 窗口测试包含按钮与穿透检查。`.github/workflows/macos.yml` 运行原生窗口、外观与五线谱回归，并编译完整应用（不生成个人签名证书）。原生 CI 通过也不替代混合 DPI、跨应用点击穿透的真实桌面验收。
