# Windows 音频平台入口 · 规划中

此目录尚无实现，不提供 Windows 采集或 FFT 后端。开发语言、原生音频 API 与打包方式留给后续实现共同确定。

## 职责与依赖

- 获取系统播放的 PCM，保留实际采样率和声道信息，提供解码、设备变化、休眠唤醒、权限与中断恢复。
- 对接 `modules/audio/core/` 的分析流程与 `SpectrumTransform` 后端接口；使用其他语言时可依据契约实现等价算法，不要求加载 Swift 二进制。
- 向进程内通道提交 `AudioFeatureFrame` 和连接状态，遵守 [音频契约](../../../../contracts/audio-features/README.md) 的时间、缺失值和代次规则。
- 不依赖 macOS 实现，也不包含小鸟、配色、窗口或具体绘图代码。通用契约不需要随 Windows 工具链选择而修改。

## 验收

使用 `contracts/audio-features/samples/` 先校验数据兼容；移植后使用已知正弦、混合音、噪声、静音及单/双声道信号对比现有数值报告。需覆盖采样率/分块变化、事件队列上限与过期、重连代次隔离，并实测系统输出回环。测试放到 `tests/audio/` 或 `tests/platforms/windows/`。尚未通过这些验收前，平台支持矩阵继续标注为规划状态。
