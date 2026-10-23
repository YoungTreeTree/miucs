# 公共笔色

两种可视化与后续模块共用一份笔色。菜单栏「线条颜色」提供石墨灰、雾蓝、苔绿、赭橙、雾紫五种选择，带色点与当前选择标记。点选后立即生效，切换模块、隐藏恢复和重启均沿用同一选择。

## 分工

- `modules/visualizations/api/VisualizationAppearance.swift` 定义平台无关的 RGB 值、五种预设与单色外观。
- `VisualizationController.applyAppearance(_:)` 更新当前绘制，并在新模块激活前传入当前外观。纯模拟不处理笔色，原生绘制适配实现该入口。
- `apps/macos/VisualizationAppearanceStore.swift` 只保存一个预设 ID：`MiucsVisualizationInk.v1`。首次升级时按旧飞鸟小鸟主色选择 RGB 距离最近的预设，旧配色 JSON 原样保留；无有效偏好时使用石墨灰。
- `VisualizationColorMenu` 提供原生菜单，应用菜单的颜色项也使用同一数据源。选择触发一次外观更新，不增加刷新计时器或逐帧颜色分析。
- 模块保留各自的线宽、透明度、渐隐与浅色衬线，所有主要笔触使用公共色。五线谱的音名缓存随颜色变化失效。

颜色更新不创建或切换会话，不改变窗口，不消费待处理起音，也不清空旋律轨迹。飞鸟的旧调色模型、数据与测试继续保留用于兼容，正常应用入口使用五色菜单。

## 验证

```sh
zsh scripts/test-appearance.sh
zsh scripts/test-palette.sh
zsh scripts/test-contracts.sh
zsh scripts/test-staff-note-platform.sh
zsh build.sh
```

[配色测试记录](validation/visualization-appearance-tests.json)覆盖存储与迁移、真实菜单动作、两种模式的即时同步、模块切换、隐藏修改、事件保留、透明度、深浅背景及文字缓存。合成预览输出到 `build/shared-color-preview/`，不包含真实桌面或音频。

新增 26 项配色检查已通过，原生菜单点选和重启后的颜色恢复也已验证；测试后恢复原配色最接近的预设。构建、严格签名及相关回归见[本轮验收记录](validation/appearance-validation.json)。
