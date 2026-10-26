# 验证记录索引

此目录同时保存当前功能检查与历史实验快照。检查通过数只表示对应测试通过，不代表识谱准确率；合成 GIF 的导出帧率也不代表真实窗口刷新率。

## 当前功能对应的记录

- [混音主旋律](predominant-mixture-validation.json)：默认来源、51 项针对性检查、安装及重启；[31 段同音频对照](predominant-mixture-benchmark.json)、[编译结束后的串行性能复测](predominant-mixture-runtime.json)。算法准确性、声音目标变化及退步见[说明](../predominant-mixture.md)。
- [轻弧水波](staff-beat-arcs-validation.json)：最新选定的节拍视觉设计、29 项绘制/生命周期检查；[满载性能](staff-beat-arcs-performance.json)、[真实窗口刷新间隔](staff-beat-arcs-cadence-800.json)。
- [平滑补线](staff-join-validation.json)：真实音高恢复时的渐进连接，保留固定谱位与静音行为；[模拟规则](staff-note-tests.json)、[原生布局绘图](staff-note-platform-tests.json)。
- [节拍识别](beat-tracker-tests.json)、[通道契约](contract-tests.json)、[音频特征](audio-feature-tests.json)、[音频管线](audio-pipeline-tests.json)、[采集恢复](audio-recovery-tests.json)。
- [旋律规则](melody-tests.json)与保留的[人声门控规则](singing-pitch-tests.json)。
- [当前五线谱合成演示元数据](staff-beat-demo.json)：对应 `docs/assets/miucs-staff-note.gif`，音频和键盘输入均为合成数据，不含用户录音或桌面。

## 历史记录

`vocal-energy-*` 记录人声相对能量门控；`staff-neural-continuity`、`staff-session-continuity*` 记录早期断线修复；`staff-beat-validation` 和 `staff-beat-compact-validation` 记录已被轻弧替代的圆环迭代。它们是对应阶段的证据，不表示当前默认来源或视觉设计。历史汇总中指向通用测试、性能或 GIF 文件的链接可能已经指向较新的结果；复核旧版本应以汇总内的时间、参数、源码/应用哈希和内嵌数值为准。

不同阶段的测试数量不可直接相加为“本次重跑数量”。性能记录区分线程 CPU、含调度等待的墙钟耗时和窗口刷新间隔；既保留通过目标的结果，也保留存在长帧的测量，不能据短测宣称所有桌面负载稳定 60fps。
