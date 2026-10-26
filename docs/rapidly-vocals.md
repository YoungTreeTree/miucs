# Rapidly 人声分离（历史）

旧版使用 Rapidly 96ms 试用 SDK 分离人声，再提取音高。其运行实现、下载脚本、构建开关与菜单入口已移除。

当前实现仅保留[混音主旋律](predominant-mixture.md)。历史实验源码及复现入口对应 Git 提交 `757e7e3`，不能使用当前构建脚本运行旧模型。

- [历史识别与性能对照](validation/rapidly-benchmark.json)
- [历史安装与验证](validation/rapidly-integration-validation.json)
- [验证记录索引](validation/README.md)

这些报告保留当时的误报、漏报、源码/输入校验和和测量限制，不代表当前应用仍包含相应 SDK 或模型。已删除的文件可由 Git 历史恢复；本地旧模型缓存和个人授权文件不属于源码清理范围。
