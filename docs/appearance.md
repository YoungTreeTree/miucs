# 画面外观

内置皮肤保留自己的角色、键盘和配色。「设置 → 外观与位置」提供 10%～100% 不透明度，每档 10%，默认 100%；作用于整个插件画面，小锁、调整控件和状态提示保持可读。

所有皮肤共用当前位置和大小。切换时不重设窗口长宽比；只有主动缩放才使用当前皮肤比例。首次升级沿用当前皮肤的旧位置，之后保存为共享记录（macOS：`MiucsSkinFrame.v1`；Windows：`SkinFrame`），重启恢复该矩形。显示器移除时按当前矩形比例缩小并移回可见范围。奶牛猫继续使用 `pixel-keyboard` 标识；改名不重置已有窗口设置。首次启动和失效的插件选择回退到奶牛猫，其他有效选择按原偏好恢复。

宿主仍保存兼容的五种笔色偏好（设置 UI 不再暴露笔色）并通过 `appearanceChanged` 传递给插件，供支持换色的自定义插件使用。内置角色图集不会被统一染色。

macOS 的 `VisualizationAppearanceStore` 保存笔色 ID 和透明度百分比，视图应用 `alphaValue`；Windows 保存 `Color` 和 `Transparency`，应用当前视图的不透明度。调整外观不重连采集、不重建会话、不增加动画计时器。缺失或损坏的颜色偏好回退到石墨灰，透明度限制到 0～90。

```sh
zsh scripts/test-appearance.sh
zsh scripts/test-visualization-host.sh
sh scripts/test-plugins.sh
```
