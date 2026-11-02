# 宿主可视化接口

`modules/visualizations/api/` 是应用内部的会话、布局和外观接口，用于窗口宿主管理插件画面。公开扩展协议是 [Lua 插件契约](../plugins/README.md)；应用只支持插件可视化。

`VisualizationRegistry` 从清单注册稳定 ID、名称、基准宽高和宽度上下限。macOS 的 `PluginSession`、Windows 的 `PluginView` 将会话适配到平台窗口；Lua 动画通过隔离 worker 运行，由 Skia 绘制。

窗口切换顺序为：保存旧位置和尺寸、暂停绘制、释放旧会话、更换插件视图、恢复目标视口、激活。选择当前 ID 不重建会话；选择未知 ID 不影响正在显示的会话。启动时优先使用已保存 ID，其次使用可用的内置插件或目录首项。空目录保留重新扫描入口。

外壳负责颜色、透明度、窗口位置、缩放、鼠标穿透、悬停锁和持久化。插件拥有输入映射、场景与动画；不控制系统采集或窗口。奶牛猫沿用 `pixel-keyboard` 标识；失效的插件选择优先回退到奶牛猫。

输入格式见 [音频契约](../audio-features/README.md) 和 [键盘契约](../keyboard-input/README.md)。音频与键盘使用独立的代次、序号及权限。宿主同帧传递两路快照和短事件，隐藏恢复、重连和切换不得补播过期事件。

新增可视化请阅读 [插件开发指南](../../docs/plugin-development.md)。
