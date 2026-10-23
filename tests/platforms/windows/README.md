# Windows 平台测试预留

当前没有 Windows 实现，不能把本目录视为已通过的 Windows 测试。

后续将真实采集/恢复、原生绘制、窗口透明/穿透、多屏位置恢复与刷新测试放在这里。数据互操作先使用 `contracts/audio-features/samples/`，音频算法使用已知合成信号和 `docs/validation/` 数值参考；通道需覆盖 64 事件容量、250ms 过期、峰值保留和代次隔离。语言与测试框架由实际实现决定。
