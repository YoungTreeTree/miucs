# Windows 应用外壳入口 · 规划中

本次仅预留协作边界，不包含可运行的 Windows 应用、项目文件或假采集实现；不限定后续开发语言。

外壳负责入口、窗口、透明背景与鼠标穿透、托盘菜单、位置/大小/配色偏好、刷新调度、模块注册与切换，并组合 Windows 音频适配与绘制适配。音频来源于 `modules/audio/platforms/windows/`，飞鸟适配位于 `modules/visualizations/pencil-flight/platforms/windows/`，五线谱适配位于 `modules/visualizations/staff-note/platforms/windows/`；平台目录之间禁止互相引用。

必须遵守 [音频契约](../../contracts/audio-features/README.md) 与 [模块契约](../../contracts/visualization/README.md)：进程内最新快照与短事件保留、一次激活一种可视化、切换释放旧会话且音频继续、休眠/中断恢复后隔离旧代次。Windows 打包、签名、权限提示和自动启动方案在真实实现时单独确定。

颜色使用公共 RGB 数据及五种预设。托盘菜单统一选择并持久化一个颜色 ID，激活前通过 `applyAppearance` 传给模块；切换颜色不影响音频、事件游标或运动状态。无需为每个模块单独实现取色器。

验收需覆盖启动/退出、透明和点击穿透、多屏位置恢复、缩放、显示刷新、音频恢复、模块切换与资源释放。依据模块布局元数据切换 400 × 260 与 800 × 160 等比例，各模块独立保存位置与大小，并记住上次选择。新会话先收到恢复后的视口再激活，音频不中断、旧事件不补播。添加实际构建命令和测试后再更新根目录平台矩阵；现有 macOS 入口与偏好键保持兼容。
