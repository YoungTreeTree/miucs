# 音频特征契约 v1

这是平台与语言无关的数据定义。当前 Swift 对应类型在 `modules/audio/core/`；Windows 可以用其他语言实现。JSON 用于验证、离线交换和协作样本，运行时通过内存对象传递，不逐帧编码 JSON。

- [frame.schema.json](frame.schema.json)：连续特征帧，包含测量和可选主旋律。
- [input.schema.json](input.schema.json)：可视化一次刷新的输入，包含连接状态、最新帧、未读起音和频谱变化峰值。
- [samples/](samples/)：固定 UUID、纯合成数值，覆盖旋律、短事件、静音、单声道和重连。没有真实录音或个人内容。

## 时间、缺失值与版本

| 字段 | 语义 |
| --- | --- |
| `version` | 当前为 `1`；破坏字段、单位或时间语义时升主版本，并保留旧样本供迁移验证 |
| `sessionID` | 每次采集重建的新 UUID，包括重新连接和停止后的新连接；旧代次回调不能写入新代次 |
| `sequence` | 每个代次内从 1 递增的接收帧序号；跨代次不能比较 |
| `audio.time`、`melody.time`、事件 `time` | PCM 分析窗口中心相对当前格式时间线的秒数；重连或输入格式改变可归零 |
| `receivedAt` | 主机单调时钟秒数，macOS 为 `systemUptime`；不是 Unix 时间，也不能与 PCM 时间相减 |
| `frameAge` | 读取时 `max(0, 单调时钟 - receivedAt)`；无帧时缺失；飞鸟对超过 400ms 的帧按失联处理 |

无效 Optional 可省略或写 `null`，不能用 `0`、NaN、Infinity 替代。零音高不能表示“没有旋律”；零相关性表示有效的不相关。`isSilent` 描述已采集声音，`state` 描述连接；运行但没有 PCM、静音 PCM、权限不足是不同状态。

格式变化会重置分析器的 PCM 时间与历史，通道序号可继续递增；消费者应检测 `sampleRate` / `channelCount` 或时间回退。采集重建则同时更换 `sessionID`。主旋律窗口与基础特征窗口不同，帧中的 `melody` 是生产时最近的估计，不能假定两个 `time` 相等。

## 字段和单位

所有数值必须有限；Float PCM 超过 ±1 时原始强度测量不截断。精确定义与算法验证见 [音频特征记录](../../docs/audio-features.md)。

| 字段 | 单位 / 范围 | 无效情况 |
| --- | --- | --- |
| `sampleRate`、`channelCount` | Hz、声道数，当前支持 1/2 声道 | 不支持格式明确报错 |
| `rms`、`peak`、`envelope` | 满幅为 1 的线性振幅；包络攻击 25ms、释放 200ms | 静音为有效零值或衰减值 |
| `rmsDBFS`、`crestDB` | dBFS / dB；dBFS 下限 -240 | 无有效信号时峰均比缺失 |
| `isSilent`、`silenceDuration` | 布尔、连续低于进入阈值的秒数 | 没有 PCM 不伪造静音帧 |
| `lowEnergy`、`midEnergy`、`highEnergy` | 20…250、250…4000、4000…20000 Hz 的线性功率；受 Nyquist 限制 | 静音为 0 |
| `lowShare`、`midShare`、`highShare` | 三频段功率和中的占比，0…1 | 无有效谱时缺失 |
| `centroidHz`、`bandwidthHz` | 振幅加权平均频率 / 标准差，Hz | 无有效谱时缺失 |
| `flatness` | 功率谱几何均值/算术均值，0…1 | 无有效谱时缺失 |
| `spectralFlux`、`onsetThreshold`、`isOnset` | 0…1 频谱变化、动态阈值、该窗口起音标记 | 第一窗口不推断起音；阈值可能大于 1 |
| `balance`、`sideEnergyRatio`、`correlation` | -1…1、0…1、-1…1 | 单声道缺失；无有效相关性时缺失 |
| `displayBands` | 24 个 0…1 的显示值 | 静音为零；不能当作能量比例 |
| `melody.pitchHz`、`confidence`、`isMelodic` | Hz、0…1 启发式置信度、有效标记 | 旋律不可确认时音高缺失；首次不足一窗时整个 `melody` 缺失 |

MIDI 半音数由 `69 + 12 log2(pitchHz/440)` 派生，不重复存入 JSON。置信度不是校准概率。可选 `melody.estimator=crepe` 表示歌声模型，缺失表示旧频谱算法；`isMelodic` 已包含该算法自己的门控。消费者须将明确的 `isMelodic=false` 当作无有效音高，即使原始混音 `audio.isSilent=false`。不能用伴奏响度延续一个已结束的音。

## 消费规则

连续状态始终只保留最新帧。`onsets` 按序保留每个订阅者未读的事件，最多 64 个，超过 250ms 的事件不补播；溢出丢弃最早事件。`strength` 为触发帧原始 `spectralFlux`，视觉力度由模块决定。

`spectralFluxPeak` 是订阅者未读区间、最近 250ms 内非静音帧的最大变化量，不受最新帧变小影响；读取后归零。当前实现用按时间过期的单调最大值队列压缩样本。新订阅者从当前序号开始，只收到最新快照，后续事件正常到达。切换模块、隐藏后恢复均不补播历史事件。对其他订阅者没有清空副作用。

`frame.audio.isOnset` 和 `spectralFlux` 保留原始测量供诊断；动作应消费独立事件和区间峰值，避免重复触发或漏掉刷新间的短事件。遇到代次变化必须清理特征历史、平滑器的输入有效性及待触发动作。

连接状态：`stopped`、`connecting`、`running`、`recovering`、`suspended`、`permissionRequired`、`userStopped`。平台适配负责采集与恢复，模块不能调用重新连接。

运行 `zsh scripts/test-contracts.sh` 验证 Schema、Swift 编解码、事件保留和跨代次隔离。Schema 用于文件边界的结构检查；代次一致、时间顺序等关联规则同时由通道和测试保证。
