# 插件虚拟运行环境与开发实验台

对应 [Issue #13](https://github.com/YoungTreeTree/miucs/issues/13)。实验台在开发机器上运行正式的 Lua 工作进程、MessagePack 输入通道、场景增量/确认协议、资源校验和 Skia CPU 渲染器。输入来自可重复的合成场景，不启动系统采集，也不读取真实键盘文字。Mac 与 Windows 使用同一套工具与 JSON 场景。

## 启动

需要 Python 3.10+，先编译本机插件运行器（依赖准备沿用项目构建脚本）：

```sh
# macOS
sh scripts/build-plugins.sh
python3 tools/plugins/lab.py serve --plugin plugins/pixel-keyboard
```

```powershell
# Windows，使用项目原有 MSVC / CMake 构建环境
./scripts/build-windows.ps1
python tools/plugins/lab.py serve --plugin plugins/pixel-keyboard
```

命令会打开本地浏览器。也可加 `--no-browser --port 8765`，手动打开终端打印的 `http://127.0.0.1:8765/`。服务只绑定 IPv4 回环地址，API 校验 Host、Origin 和每次启动生成的会话 token；不提供远程访问，不上传数据。

`--plugin /path/to/my-plugin` 加载任意文件夹插件；内置插件仍在选择列表中，方便测试切换。重复 ID 会明确报错。浏览器只能操作启动时登记的插件，不能通过请求传入任意文件路径。

## 交互工作流

1. 选择插件与预设，点击“加载场景”。默认预设为音乐与打字。
2. 播放、暂停、单步，拖动时间轴定位。定位会从种子与已保存的时间线重新执行，不猜测或复制 Lua 内部状态。
3. 调整音频、按键、权限/连接状态、窗口尺寸、DPI、颜色和透明度，或注入隐藏、休眠、恢复、卡顿事件。每次手动操作在当前虚拟时间写入场景，推进一帧后生效。场景结束后的新操作从起点开始。
4. 在“编辑完整信号与时间线”中读取、编辑、下载或导入 JSON。完整契约中的频谱、置信度、事件年龄和丢失计数等通过 JSON 设置。
5. 修改 Lua 后点击“重载插件”，或开启自动重载。新实例通过加载、激活、更新探测和资源绘制检查后替换；失败显示错误并保留旧实例。重载重置动画，保留当前视口和外观。文件监听每秒轮询一次，场景未结束时自动重载也记录为事件并推进一帧；结束后仅刷新实例。脚本与资源共用正式目录约束。
6. 查看当前输入、筛选场景节点、导出报告与 PNG。报告写入 `--output` 指定目录，默认 `build/plugin-lab/`；同目录的上次导出会被覆盖。

播放按小批次推进虚拟帧，浏览器约每批显示一次预览。它适合调试动画状态与几何，不是 60 Hz 原生浮窗性能测试。暂停停止虚拟时间；隐藏/休眠仍允许测试时间流逝，但停止插件更新，清除过期事件；恢复不会补播隐藏期间按键。

## 场景格式 v1

```json
{
  "version": 1,
  "name": "断连后恢复",
  "seed": 42,
  "fps": 60,
  "duration": 8,
  "initial": {
    "audio": {"bpm": 120, "pitchHz": 440, "pitchSweep": 0},
    "keyboard": {"rate": 0},
    "viewport": {"width": 800, "height": 160, "scale": 1}
  },
  "events": [
    {"at": 1, "type": "press", "value": {"key": "a"}},
    {"at": 1.5, "type": "release", "value": {"key": "a"}},
    {"at": 2, "type": "audio", "value": {"state": "recovering"}},
    {"at": 3, "type": "audio", "value": {"state": "running"}},
    {"at": 4, "type": "reconnect", "value": "keyboard"},
    {"at": 5, "type": "hide"},
    {"at": 6, "type": "show"}
  ]
}
```

`at` 是场景开始后的秒数；事件在首个起始时间达到 `at` 的帧执行，同一时间按文件顺序执行。场景结束时刻的事件不会执行，应安排在 `duration` 之前。`stall` 把下一帧间隔额外增加指定秒数，跨过的时间点在下一帧执行，不补生成一大批自动按键或节拍。最后一帧可以越过 `duration`。

宿主单调时间从 1 开始，音频分析时间从 1000 开始，特意使用不同时间域以发现混算错误。音频和键盘各自维护 sessionID 与序号；状态变化/重连仅重置相应输入，显示恢复会重新建立两路订阅。`seed` 传给正式运行器的 `miucs.random()`，不开放 Lua 系统随机数或时钟。

### 信号覆盖

| 类别 | 可配置/模拟 | 默认与边界 |
| --- | --- | --- |
| 音量 | `rms`、`peak`、`envelope`、`silent`；派生 dBFS、静音时长 | 线性幅度 0..1 |
| 音高 | `pitchHz`、`pitchSweep`（半音正弦幅度）、`confidence`、`melodic` | 无旋律时 pitch 为 null |
| 节奏 | `bpm`、`beatConfidence`、`beatStrength`、`onsetStrength`；手动 `beat`/`onset` | BPM 0 关闭自动节拍 |
| 频谱 | `lowEnergy`、`midEnergy`、`highEnergy`、`flux`、`onsetThreshold`、`centroidHz`、`bandwidthHz`、`flatness`、`bands` | 恰好 24 个显示频带；模拟特征可独立调节 |
| 音频格式 | `sampleRate`、`channelCount` | 特征元数据，不重新运行 FFT/音高分析器 |
| 音频状态 | `stopped`、`connecting`、`running`、`recovering`、`suspended`、`permissionRequired`、`userStopped` | 非 running 时 frame 为 null |
| 键盘状态 | `stopped`、`connecting`、`running`、`recovering`、`suspended`、`permissionRequired`、`secureInput` | 不可用时不产生按键事件 |
| 键盘输入 | `rate`、`keys`、`modifiers`；手动 `press`、`repeat`、`release`、`modifiers` | 统一物理键标识；自动键约 80 ms 后释放 |
| 键盘派生值 | heldKeys、heldDuration、pressesPerSecond、idleDuration、sequence | 不含输入文字 |
| 通道可靠性 | `age`、`drop`、`reconnect` | 事件 TTL 250 ms；每帧最多 128 键事件、64 节拍、64 起音；超出计入丢失数 |
| 宿主时间 | `fps`、`stall`、固定 seed、暂停/单步/定位 | fps 1..120；stall 0..5 s |
| 输出生命周期 | `hide/show`、`suspend/resume`、`resize`、`appearance`、`switch`、`reload` | 插件切换目标须预先登记 |

`audio` / `keyboard` 事件用对象局部覆盖控制值；`press/repeat/release` 值为 `{ "key": "a", "age": 0 }`；`beat/onset` 值为 0..1 强度；`reconnect` 值为 `audio` 或 `keyboard`；`modifiers` 为契约位掩码；`fps/stall` 值为数字；`switch` 值为插件 ID；`resize` 值为 width/height/scale；`appearance` 值为 ink/opacity；其余生命周期事件无 value。

`drop` 是每帧额外模拟的丢失数，`age` 是接收年龄。音频快照年龄会传给插件决定是否采纳；过期的离散事件在宿主端丢弃。`press` 的 age 可单独覆盖以构造陈旧事件。修饰键位和物理键名遵循 `contracts/keyboard-input/`。

预设包含音乐打字、静音、组合键长按、独立重连、权限不可用、频谱边界、生命周期及四插件切换。场景最多 60 秒、2048 个事件、1 MiB JSON；预览最多 4 百万像素。长时间内存增长/物理性能验收仍使用正式应用。

## 自动化与证据

```sh
python3 tools/plugins/lab.py run --plugin plugins/pixel-keyboard --scenario keyboard --output build/lab-keyboard
python3 tools/plugins/lab.py run --plugin plugins/pixel-keyboard --scenario /path/to/scenario.json --output build/lab-custom
python3 tests/plugins/lab_test.py
```

产物：

- `scenario.json`：可分享、可再次执行的种子、初始参数和操作时间线。
- `frames.ndjson`：每帧实际输入、宿主操作、场景 SHA-256 和运行数据。
- `scene.json`：末帧统一场景与原生运行器诊断。
- `preview.png`：末帧透明 PNG，使用正式 Skia CPU 绘图。
- `report.json`：更新耗时 P95、宿主往返与检查耗时 P95、末次 CPU 绘制耗时、Lua/场景内存估计与最终场景 hash。
- `failure.json`：命令行运行异常时保存错误、最后输入状态与场景，进程以非零状态退出。

同机器、同插件内容、同场景与 seed 的回放应得到相同节点 hash；CPU 时间不参与 hash。跨平台比较时允许浮点/三角函数的微小差异，应进一步比较路径数值容差和 PNG，而不能只用严格 hash 作渲染一致性结论。报告中的往返耗时包含同步等待与完整诊断序列化，不代表生产提交耗时。

自动测试覆盖四个内置插件 × 八个预设、重复回放、seed 差异、定位、两路重连、TTL/容量、组合按键、隐藏恢复、加载/更新/无限循环/损坏资源重载失败保留旧实例、HTTP 访问边界；原生运行器和 transport 测试继续覆盖内存上限、脚本/资源路径限制、字节码拒绝及工作进程隔离。Mac/Windows 插件 CI 均运行实验台测试。

## 实现边界

浏览器只编辑场景并显示 CPU 位图。Python 虚拟宿主发送正式二进制输入，Lua 仍在独立受限工作进程执行。为调试新增的 `miucs_plugin_open_seeded` 和 `miucs_plugin_inspect` C ABI 是可选接口；正式应用没有逐帧 JSON 检查开销。旧 ABI 保持兼容。

实验台不虚构目前基座没有提供的鼠标、网络、电池、前台应用等信号，不开放 PCM、任意系统 API 或真实输入文字。OS 权限弹窗、设备热插拔、屏幕锁定与 DPI 通知使用宿主事件模拟；真实 Metal / D3D12 / DirectComposition、屏幕鼠标穿透、系统采集正确性、GPU 延迟和掉帧率必须在平台应用中验收。场景脚本/资源文件不打包进回放文件，复现时需使用相同插件版本与内容；热重载历史也不保存每个文件版本。

## 所有皮肤的统一输入 GIF

安装 GIF 编码依赖（仅开发工具需要）：

```sh
python3 -m pip install -r tools/plugins/requirements.txt
python3 tools/plugins/lab.py gifs --scenario music-typing --output build/plugin-lab
# 缩短预览、调整输出帧率与最长边
python3 tools/plugins/lab.py gifs --scenario music-typing --seconds 6 --gif-fps 20 --gif-width 480
```

页面中的“全部皮肤 GIF”使用**当前已加载的完整场景**，从起点为所有已登记皮肤各运行一个独立实例；不会改变当前调试实例的时间、选择、动画状态或输入记录。可设置 GIF 帧率、最长边和时长。导出期间暂停交互回放，完成后可分别下载 GIF，或下载包含全部 GIF、预览网页与输入记录的 ZIP。

每个皮肤使用相同场景、随机种子、单调时间与事件序列。先生成一份公共 `inputs.ndjson`，再校验提交给每个皮肤运行器的输入与公共记录 SHA-256 完全一致。运行器仍按插件声明过滤未申请的输入能力。皮肤切换事件会统一忽略并记在清单中，避免所有预览中途切成同一个皮肤；音频、键盘、隐藏恢复、外观与尺寸等事件仍会执行。未显式指定视口时保留各皮肤默认宽高比。

动画仍按场景原始帧率推进（默认 60 FPS），GIF 默认采样 16 FPS，展示采样时刻之前已完成更新的场景。模拟卡顿时保持上一帧；隐藏/休眠时显示空白背景。每张 GIF 循环播放，最长边默认 640 像素，固定画布以适应中途 resize。GIF 不支持半透明，因此使用统一暖白背景 `#f6f4ef` 合成，保留柔和描边。GIF 的时间单位为 10 ms，帧时长按累计时间分配，避免 16 FPS 被统一截短导致加速。

`--output` 下的 `gifs/` 包含：

- `<插件ID>.gif`：每个成功导出的皮肤一张动态预览。
- `index.html`：可本地打开的并排预览页。
- `scenario.json`、`inputs.ndjson`：实际使用的场景与公共输入流。
- `manifest.json`：种子、输入哈希、每个 GIF 的尺寸/帧数/时长、忽略的切换事件和失败原因。
- `previews.zip`：以上文件的完整分享包。

同目录再次导出会替换本次生成的同名文件。失败皮肤不会列出下载链接，并清除同目录下该皮肤上次生成的 GIF，其他皮肤继续导出；命令行有任一失败时返回非零状态。单皮肤调色板帧缓存上限 128 MiB，超限时降低尺寸、帧率或时长。`python3 tests/plugins/gif_test.py` 检查真实 GIF 解码、循环时长、共享输入、重复导出、预乘透明度、隐藏/缩放、部分失败与 HTTP 下载边界。
