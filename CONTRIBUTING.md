# 参与 Miucs 开发

当前可运行版本是 macOS 原生应用。请先阅读 [架构说明](docs/architecture.md)、[音频契约](contracts/audio-features/README.md) 和 [可视化契约](contracts/visualization/README.md)。Windows 欢迎共同设计实现，但目前没有可运行应用。

## 平台支持

| 平台 | 音频采集 / 恢复 | 分析后端 | 铅笔飞鸟绘制 | 应用外壳 |
| --- | --- | --- | --- | --- |
| macOS 14+ / Apple Silicon | 已实现，含自动恢复 | Swift 分析 + Accelerate FFT | AppKit，含配色设置 | 已实现 |
| Windows | 规划中 | 未实现；语言待定 | 规划中；工具箱待定 | 规划中 |

通用核心当前以 Swift 源码实现。语言无关契约与样本为跨平台协作入口，不表示 Windows 已能直接构建这些代码。

## 本地开发

需要 Swift 6 的 Xcode 或 Command Line Tools；首次本地签名需要 OpenSSL 3。`build.sh` 保持稳定应用标识和 `Miucs Dev` 开发签名，产物在忽略的 `dist/`。如使用 Xcode，可用项目现有的 `project.yml` 生成工程。

```sh
zsh build.sh
open dist/Miucs.app
```

只修改模块时优先进入相应 `core/` 或 `platforms/macos/`。`scripts/swift-sources.sh` 定义编译分组；新增目录时同时更新它和 `project.yml`。应用组合点是 `apps/macos/BuiltInVisualizations.swift`。

离线参考和资源工具需要 Python；应用运行不依赖 Python：

```sh
python3 -m pip install -r tests/requirements.txt
```

## 测试与诊断

以下命令从仓库根目录执行，不改变个人位置或配色偏好。原生窗口与调色盘测试使用独立偏好域。

```sh
zsh scripts/test-contracts.sh       # 依赖边界、Schema、通道与会话切换
zsh scripts/test-flight.sh          # 飞鸟规则，含距离/体积/气团
zsh scripts/test-melody.sh          # 合成独奏/伴奏与响应时序
zsh scripts/test-audio-pipeline.sh  # 分析编排等价与格式切换
zsh scripts/test-audio-recovery.sh  # 采集生命周期、退避与迟到回调
zsh scripts/test-palette.sh         # 颜色存储、真实绘图与调色盘
zsh scripts/test-visualization-host.sh # 原生视图切换、资源释放和窗口兼容
zsh scripts/validate-audio.sh       # 基础音频与独立 NumPy 参考
```

构建后运行窗口验证与预览：

```sh
dist/Miucs.app/Contents/MacOS/Miucs --verify-flight-window --output docs/validation/flight-window-tests.json
dist/Miucs.app/Contents/MacOS/Miucs --render-flight-preview --output build/flight-preview
```

实际系统回放检查需要已授予系统音频捕获权限，会播放约 12 秒合成低幅度测试音：

```sh
zsh scripts/validate-audio.sh --live
```

其他现有入口保持可用：

```sh
zsh scripts/analyze-audio-file.sh /absolute/input.wav /absolute/features.json
python3 scripts/evaluate-melody.py --help
zsh scripts/measure-performance.sh
zsh scripts/measure-performance.sh --cadence
zsh scripts/render-demo.sh --desktop
zsh scripts/render-demo.sh --close-up
```

生成的 WAV、逐帧诊断、临时可执行文件在 `build/`；摘要报告在 `docs/validation/`。合成 GIF 的导出器只生成模拟桌面，不能将真实桌面、播放内容、路径或账号信息放入公开示例。性能测量方法与限制见报告，位图耗时不能代替屏幕呈现帧率。`--cadence` 会短暂显示合成测试窗口，需要解锁桌面并保持显示器唤醒；显示休眠期间系统会暂停同步回调。

## 新增可视化模块

1. 新建 `modules/visualizations/<stable-id>/core/`，实现 `VisualizationSession` 与自己的场景状态；稳定 ID 使用不会随显示名改变的字符串。
2. 消费连续特征、独立起音事件和区间峰值；按代次/序号去重并处理静音、失联、缺失旋律。数据单位以契约为准，映射与平滑属于本模块。
3. 在 `platforms/macos/` 实现 `MacVisualizationSession`，提供原生视图和可选设置入口；停用/释放应幂等，关闭设置窗口并取消自身订阅。原生 UI 类型不能进入通用 API。
4. 在 `BuiltInVisualizations.registry()` 添加工厂注册；更新编译目录分组和 Xcode 源目录。菜单自动读取注册表，只显示当前模块。无需修改音频分析或采集代码。
5. 在 `tests/visualizations/` 添加合成数据驱动的规则测试，在 `tests/platforms/macos/` 添加需要原生环境的测试；运行契约与原生切换测试。不要把测试用第二模块注册进正式应用。

当前支持编译内置模块，不包括运行时加载第三方二进制。通用注册表中的测试模块展示了无需改动音频即可切换；原生宿主测试验证视图与资源清理。

## Windows 接入

分别从 [音频适配](modules/audio/platforms/windows/README.md)、[飞鸟绘制](modules/visualizations/pencil-flight/platforms/windows/README.md) 和 [应用外壳](apps/windows/README.md) 开始。先通过 Schema 与合成样本验证时间、单位、缺失值、事件容量和重连隔离，再做平台采集/恢复、绘制与窗口测试。

Windows 可选择其他语言；优先维持数据语义与可复现数值，不引入 macOS 目录依赖。实际实现确定工具链后补充构建入口与 CI，在真实平台通过验收后更新支持矩阵。预留目录仅放职责说明，不用返回假数据的空实现表示支持。
