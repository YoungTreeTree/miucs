# 画面外观

四个插件保留自己的角色、键盘和配色。菜单提供 10%～100% 不透明度，每档 10%，默认 100%；作用于整个插件画面，小锁、调整控件和状态提示保持可读。

每个插件独立保存位置和大小。奶牛猫继续使用 `pixel-keyboard` 标识；改名不重置已有窗口设置。首次启动和失效的插件选择回退到奶牛猫，其他有效选择按原偏好恢复。

宿主仍提供五种笔色并通过 `appearanceChanged` 传递给插件，供支持换色的自定义插件使用。内置角色图集不会被统一染色。

macOS 的 `VisualizationAppearanceStore` 保存笔色 ID 和透明度百分比，视图应用 `alphaValue`；Windows 保存 `Color` 和 `Transparency`，应用当前视图的不透明度。调整外观不重连采集、不重建会话、不增加动画计时器。缺失或损坏的颜色偏好回退到石墨灰，透明度限制到 0～90。

```sh
zsh scripts/test-appearance.sh
zsh scripts/test-visualization-host.sh
sh scripts/test-plugins.sh
```
