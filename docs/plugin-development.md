# 插件开发指南

Miucs 插件用 Lua 5.4 描述场景和动画，由共享的 Skia 渲染器绘制。插件接收宿主已经分析好的音频特征与物理按键，不需要编写音频采集、窗口或菜单代码。

一个插件文件夹对应一个可视化，名称直接显示在「可视化」菜单里。同一时间只运行选中的插件；菜单栏猫图标由应用独立管理。以下命令均从仓库根目录执行。

## 1. 准备应用

插件是唯一的可视化运行方式。所有构建包含运行库和内置插件；修改 Lua 或资源不需要重新构建应用。

### macOS

需要 macOS 14+ / Apple Silicon、Swift 6、C++ 工具链、Python 3.10+、CMake 3.24+；首次开发签名还需要 OpenSSL 3。

```sh
zsh build.sh
open dist/Miucs.app
```

### Windows

需要 .NET 8、Visual Studio C++ Build Tools、Python 3.10+ 和 CMake 3.24+。在可使用 C++ 工具链的 PowerShell 中执行：

```powershell
./scripts/build-windows.ps1 -Runtime win-x64
./dist/windows/win-x64/Miucs.exe
```

首次构建会下载并校验 Lua、JSON 库和 Skia 依赖。更新后先退出已运行的 Miucs，再打开新版本。应用不再提供原生可视化或模式切换参数。

Windows 实机验收与插件性能验收尚未全部完成；状态和底层实现说明见[插件迁移记录](plugin-migration.md)。

## 2. 从模板创建插件

以一个随音量放大的圆为例，在本地 `build/` 中创建开发副本：

```sh
mkdir -p build
cp -R tools/plugins/template build/my-pulse
```

Windows PowerShell 对应命令：

```powershell
New-Item -ItemType Directory -Force build | Out-Null
Copy-Item tools/plugins/template build/my-pulse -Recurse
```

首次复制时使用一个尚不存在的目标目录。文件结构为：

```text
my-pulse/
├── manifest.json   # 插件标识、菜单名称、输入和尺寸
├── main.lua        # 生命周期与动画
├── scene.lua       # 初始场景
└── assets/         # 可选：图片、字体及其许可文件
```

将三个文件替换为下面的内容。`manifest.id`、场景根节点 ID、代码里的插件 ID 必须一致；只改文件夹名称不会改变插件身份。

### manifest.json

```json
{
  "id": "my-pulse",
  "name": "我的音量圆",
  "version": "1.0.0",
  "api": 1,
  "entry": "main.lua",
  "inputs": ["audio"],
  "layout": {
    "width": 240,
    "height": 160,
    "minimumWidth": 120,
    "maximumWidth": 960
  }
}
```

- `id`：稳定且唯一，最多 128 个 ASCII 字母、数字、`.`、`_` 或 `-`。不要与内置插件重名；用户插件不能覆盖内置 ID。
- `name`：菜单显示名称；`version`：插件版本字符串；`api`：当前为 `1`。
- `entry`：包内 Lua 入口文件；`inputs`：按需声明 `audio`、`keyboard`，或使用空数组。未声明的数据不会送入插件。
- `layout`：设计尺寸与允许宽度，必须满足 `0 < minimumWidth <= width <= maximumWidth <= 4096`、`0 < height <= 4096`。

不要添加旧版 `visualizations` 数组或 `tray` 字段，当前运行时会拒绝它们。完整定义见 [manifest Schema](../contracts/plugins/manifest.schema.json)。

### scene.lua

```lua
return {
  type = "group", id = "my-pulse", width = 240, height = 160,
  children = {
    {type = "ellipse", id = "pulse", x = 96, y = 56,
     width = 48, height = 48, fill = "#3d3d3d"}
  }
}
```

### main.lua

```lua
local active = false
local radius = 24

return {
  create = function(context)
    miucs.load(miucs.require("scene.lua"))
  end,
  activate = function(viewport)
    active = viewport.id == "my-pulse"
    radius = 24
  end,
  update = function(frame)
    if not active then return end
    local input = frame.audio
    local envelope = 0
    if input and input.state == "running" and input.frame
        and input.frameAge and input.frameAge < 0.4 then
      envelope = input.frame.audio.envelope
    end
    local target = 24 + math.min(1, math.max(0, envelope) * 8) * 28
    radius = radius + (target - radius)
        * (1 - math.exp(-frame.deltaTime / 0.08))
    miucs.set("pulse", {
      width = radius * 2, height = radius * 2,
      x = 120 - radius, y = 80 - radius
    })
  end,
  resize = function(viewport)
    -- 宿主按根节点设计尺寸等比缩放，无需重新创建场景。
  end,
  appearanceChanged = function(appearance)
    miucs.set("pulse", {fill = appearance.ink or "#3d3d3d"})
    miucs.set("my-pulse", {opacity = appearance.opacity or 1})
  end,
  deactivate = function() active = false end,
  dispose = function() active = false end
}
```

该示例没有图片或字体依赖。音乐播放时圆随音量平滑放大；静音、未授权或数据过期时回到基础大小。全局笔色通过 `appearanceChanged` 应用；Windows 传入不透明度，macOS 当前由宿主视图统一淡化，未传入时使用 `1`。

## 3. 验证并导出预览

完成第 1 步构建后执行：

```sh
python3 tools/plugins/validate.py build/my-pulse
python3 tools/plugins/preview.py --plugin build/my-pulse --output build/my-pulse-preview
```

Windows 使用 `python` 替换 `python3`。这两个工具只使用 Python 标准库，但需要已构建的插件 worker 和渲染库；它们会自动选择 macOS 或 Windows Release 产物。

验证器运行真实 Lua worker，检查生命周期、合成输入和资源解码。预览器输入合成音频与按键，并通过 Skia CPU 渲染器输出 `build/my-pulse-preview/my-pulse.png`。预览是最终一帧的静态 PNG，不是动画，也不会读取你的系统音频或真实按键。

## 4. 安装到应用

将**整个插件文件夹**放入用户插件目录，确保 `manifest.json` 就在该文件夹的第一层：

| 平台 | 用户插件目录 |
| --- | --- |
| macOS | `~/Library/Application Support/Miucs/Plugins/` |
| Windows | `%LOCALAPPDATA%\Miucs\Plugins\` |

macOS 首次安装：

```sh
mkdir -p "$HOME/Library/Application Support/Miucs/Plugins"
cp -R build/my-pulse "$HOME/Library/Application Support/Miucs/Plugins/my-pulse"
```

Windows 首次安装：

```powershell
$pluginRoot = Join-Path $env:LOCALAPPDATA 'Miucs\Plugins'
New-Item -ItemType Directory -Force $pluginRoot | Out-Null
Copy-Item build/my-pulse (Join-Path $pluginRoot 'my-pulse') -Recurse
```

然后在应用菜单选择「重新扫描插件」，再从「可视化」选择「我的音量圆」。仅扫描不会运行脚本；选中后才启动对应 worker。后续可直接编辑安装目录中的文件，或将本地修改同步到该目录，避免重复复制时多嵌套一层文件夹。

位置、大小、颜色和当前选择由宿主保存。切换插件释放旧 worker；隐藏画面暂停更新，恢复时不会补播隐藏期间的输入。

## 5. 修改与热重载

修改已安装插件的 Lua 或资源后，选择「重新加载当前插件」。宿主会启动候选 worker，并验证其首帧；成功后替换旧实例，动画重新开始，窗口位置及外观偏好保留。失败时保留旧实例，可从菜单的插件状态查看错误。

需要自动重载时，先退出应用，再启动：

```sh
MIUCS_PLUGIN_DEV=1 dist/Miucs.app/Contents/MacOS/Miucs
```

```powershell
$env:MIUCS_PLUGIN_DEV = '1'
./dist/windows/win-x64/Miucs.exe
```

开发模式约每秒检查当前已加载插件的文件变更。修改名称或布局等 manifest 元数据后要重新扫描；若当前实例仍使用旧描述，切换到其他插件再切回来。修改 `id` 会被视为新插件，需要同步场景根节点和代码。编辑仓库中的副本不会自动更新安装目录。

## 场景与输入速查

| 接口 | 用途 |
| --- | --- |
| `miucs.load(tree)` | 创建持久场景节点，通常在 `create` 中调用 |
| `miucs.set(id, properties)` | 更新已有节点的属性；不能修改身份或层级 |
| `miucs.require("file.lua")` | 加载包内 Lua 源码，每个 worker 缓存一次 |
| `miucs.random()` | 获取可复现的伪随机数 |

支持 `group`、`path`、`image`、`text`、`rect`、`ellipse`。坐标原点在左上角，x 向右、y 向下，旋转为顺时针弧度。根节点尺寸定义设计空间，宿主按比例适配窗口；不必在每次 `resize` 时重建节点。

图片和字体必须随包附带，使用 `assets/cat.png` 这样的相对路径，不能访问包外路径。像素图可设置 `sampling = "nearest"`，图集用 `sourceRect`；文字节点需要指定包内字体。每帧复用节点并更新属性，避免持续增加节点或无限增长轨迹。其他属性见 [Lua 编辑器定义](../contracts/plugins/api.lua)，可将其所在目录加入 Lua Language Server 的 workspace library，勿在插件内加载该定义文件。

生命周期回调均可选。`create` 建立场景；`activate` 开始运行；`update` 更新动画；`resize` 与 `appearanceChanged` 接收宿主变化；`deactivate`、`dispose` 负责暂停和清理，清理逻辑应能重复调用。外观可能在激活前应用，节点应在 `create` 阶段准备好。

`update(frame)` 中常用的数据：

| 数据 | 含义 |
| --- | --- |
| `frame.deltaTime` / `frame.now` | 实际经过的秒数 / 宿主单调时钟 |
| `frame.audio.state` / `frame.audio.frameAge` | 音频状态 / 当前快照的年龄 |
| `frame.audio.frame.audio` | 音量包络、能量、频谱等连续特征 |
| `frame.audio.frame.melody` | 旋律音高与可靠性，可能缺失 |
| `frame.audio.onsets` / `frame.audio.beats` | 起音 / 节拍事件 |
| `frame.keyboard.events` / `heldKeys` | 按键事件 / 当前按住的物理键 |
| `frame.keyboard.pressesPerSecond` | 打字速度 |

要响应键盘，在 manifest 中声明 `"inputs": ["audio", "keyboard"]`，并在 `update` 中读取物理键名，例如：

```lua
local keyboard = frame.keyboard
if keyboard and keyboard.state == "running" then
  for _, event in ipairs(keyboard.events) do
    if event.kind == "pressed" and event.key == "space" then
      -- 在这里触发空格键动画；不是输入文字。
    end
  end
end
```

该片段放在 `update(frame)` 内，且位于活动状态检查之后。输入可能未授权、失联或缺失，读取前先检查。音频与键盘的 `sessionID` 独立变化，若自行保存序号或轨迹，应分别重置；未知键名可能为 `nil`。不要混用音频时间轴与宿主时钟，遇到较大的 `deltaTime` 应让动画收敛，避免补播大量旧动作。完整格式见[插件 API](../contracts/plugins/README.md)、[音频输入 Schema](../contracts/audio-features/input.schema.json)和[键盘契约](../contracts/keyboard-input/README.md)。

## 常见问题

| 现象 | 检查项 |
| --- | --- |
| 没有重新扫描菜单 | 请确认运行的是更新后的完整应用 |
| 扫描后没有自己的插件 | 文件夹层级、manifest 格式、重复 ID；查看菜单插件错误 |
| 菜单能选中但没有画面 | 根节点 ID 是否匹配 manifest，是否调用 `miucs.load`；先运行验证和预览 |
| 改名后动画不动 | 模板 `activate` 中是否仍判断 `example-pulse` |
| 修改后画面仍旧 | 是否编辑了安装副本、是否启用重载；重载失败会保留旧画面 |
| 没有音频或键盘反应 | manifest 是否声明输入、系统权限和菜单连接状态是否正常 |
| 图片或文字不显示 | 资源是否在包内、路径大小写是否一致、字体是否随包附带 |

## 分享与参考

分享整个插件文件夹即可，附上使用说明、适用 API 版本及图片/字体许可证。接收者需要插件版 Miucs，将文件夹放入用户目录后重新扫描。无需附带构建缓存、worker 或宿主运行库；目前没有在线插件市场或自动更新器。

Lua 不能直接访问网络、文件系统、原始 PCM 或输入文字。独立 worker 用于故障隔离，并非操作系统级安全沙箱；安装插件仍需信任其来源。运行时限制、资源上限和性能要求见[插件 API](../contracts/plugins/README.md)。

可直接参考三个相互独立的内置包：

- [铅笔飞鸟](../plugins/pencil-flight/)：音频特征映射、路径与粒子。
- [五线谱音符](../plugins/staff-note/)：旋律轨迹、键盘星星与节拍轻弧。
- [像素音乐键盘](../plugins/pixel-keyboard/)：物理按键、图集和像素动画。

修改宿主或运行时的开发者可继续阅读[贡献指南](../CONTRIBUTING.md)和[插件迁移与验收记录](plugin-migration.md)。
