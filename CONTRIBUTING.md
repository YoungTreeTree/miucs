# 参与 Miucs 开发

当前可运行版本是 macOS 原生应用。请先阅读 [架构说明](docs/architecture.md)、[音频契约](contracts/audio-features/README.md) 和 [可视化契约](contracts/visualization/README.md)。Windows 已新增独立 .NET 8/WPF 实现和构建入口；跨平台核心测试/交叉构建与 Windows 实机验收分开记录，后者尚待执行。

## 平台支持

| 平台 | 音频采集 / 恢复 | 分析后端 | 铅笔飞鸟绘制 | 五线谱音符绘制 | 应用外壳 |
| --- | --- | --- | --- | --- | --- |
| macOS 14+ / Apple Silicon | 已实现，含自动恢复 | Swift 分析 + Accelerate FFT | Lua/Skia，共用五种笔色 | Lua/Skia，共用五种笔色 | 已实现 |
| Windows 10/11 x64 | WASAPI 已实现；实机待验 | C# FFT/混音旋律/节拍；合成测试 | Lua/Skia；实机待验 | Lua/Skia；实机待验 | 托盘/透明窗口已实现；实机待验 |

通用核心当前以 Swift 源码实现。语言无关契约与样本为跨平台协作入口，不表示 Windows 已能直接构建这些代码。

## 本地开发

需要 Swift 6 的 Xcode 或 Command Line Tools；首次本地签名需要 OpenSSL 3。`build.sh` 保持稳定应用标识和 `Miucs Dev` 开发签名，产物在忽略的 `dist/`。如使用 Xcode，可用项目现有的 `project.yml` 生成工程。

```sh
zsh build.sh
open dist/Miucs.app
```


只修改模块时优先进入相应 `core/` 或 `platforms/macos/`。`scripts/swift-sources.sh` 通过模块目录通配符定义编译分组；增加目录时也要更新 `project.yml`。应用组合点是 `apps/macos/PluginVisualizations.swift`，只注册插件目录中的可视化。

离线参考和资源工具需要 Python；应用运行不依赖 Python：

```sh
python3 -m pip install -r tests/requirements.txt
```

## 测试与诊断

以下命令从仓库根目录执行，不改变个人位置或配色偏好。窗口与外观测试使用独立偏好域。

```sh
zsh scripts/test-contracts.sh       # 依赖边界、Schema、通道与会话切换
zsh scripts/test-keyboard.sh        # 键盘通道、并行输入、权限/休眠/重连和原生事件解码
zsh scripts/test-beat-tracker.sh    # 原始 PCM 节拍、半速/倍速、变速、静音和时序
zsh scripts/test-melody.sh          # 合成独奏/伴奏与响应时序
zsh scripts/test-audio-pipeline.sh  # 分析编排等价与格式切换
zsh scripts/test-audio-recovery.sh  # 采集生命周期、退避与迟到回调
zsh scripts/test-appearance.sh      # 全局五色、菜单选择、偏好迁移与会话切换
zsh scripts/test-visualization-host.sh # 原生视图切换、资源释放和窗口兼容
zsh scripts/validate-audio.sh       # 基础音频与独立 NumPy 参考
```

构建后运行输入诊断：

```sh
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
```

生成的 WAV、逐帧诊断和临时可执行文件在 `build/`。历史原生绘制报告保留在 `docs/validation/`，不代表当前插件的验收结果。

## 新增可视化

所有可视化均使用 Lua/Skia 插件。按 [插件开发指南](docs/plugin-development.md) 复制模板、声明清单、编写场景与动画，再安装到用户目录。不要向宿主添加原生绘制器或模式开关。

```sh
sh scripts/build-plugins.sh
sh scripts/test-plugins.sh          # C++ 运行库、固定数值回放、预览、传输与生命周期
zsh scripts/test-plugin-macos.sh    # macOS 插件选择、独立 worker、热重载和托盘
python3 tools/plugins/validate.py plugins/staff-note
python3 tools/plugins/preview.py
```

数值回放使用 `tests/plugins/reference.json.gz` 中的固定参考，覆盖三个原有插件各 600 帧。参考来自移除前的模拟器，输入哈希防止测试数据无意漂移；维护说明见 [测试基线](tests/plugins/README.md)。性能测试使用 `build/plugins/plugin-benchmark`，持续内存检查使用 `tests/plugins/soak.py`。

## Windows 接入

分别从 [音频适配](modules/audio/platforms/windows/README.md)、[插件契约](contracts/plugins/README.md) 和 [应用外壳](apps/windows/README.md) 开始。先验证数据契约，再检查平台采集、恢复、插件绘制与窗口。

Windows 使用 .NET 8/C# 与 WPF，不引入 macOS 目录依赖。`scripts/build-windows.ps1` 先执行可移植核心测试再发布；Linux 也可运行 `scripts/test-windows.sh` 进行测试及交叉构建。新增 `.github/workflows/windows.yml` 包含 Windows 离屏检查；工作流未在本轮远程运行。真实平台验收见 `docs/windows-acceptance.md`，通过前不宣称完整稳定支持。


混音主旋律是唯一运行路径。修改时运行 `test-melody.sh`、`test-audio-pipeline.sh`、`test-audio-recovery.sh` 及插件回放；识别质量使用 `python3 scripts/benchmark-pop-melody.py --output build/current-mixture-benchmark.json`，需要已准备的本地音频样本。首次准备命令见上方歌曲基准。此前人声分离对照仅保留历史报告，可从提交 `757e7e3` 恢复相应实验代码；当前构建不下载或打包 SDK/模型。验证入口见[验证索引](docs/validation/README.md)。

## 悬浮锁回归

双端悬浮 3 秒的小锁入口与菜单共用调整状态，设计与实机检查见 [悬浮锁说明](docs/hover-lock.md)。Windows 核心测试包含悬浮等待状态；macOS 窗口测试包含按钮与穿透检查。`.github/workflows/macos.yml` 运行窗口与外观回归，并编译完整应用（不生成个人签名证书）。原生 CI 通过也不替代混合 DPI、跨应用点击穿透的真实桌面验收。
