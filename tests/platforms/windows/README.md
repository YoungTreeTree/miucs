# Windows 平台测试

`CoreTests` 可在 macOS、Linux 和 Windows 运行，覆盖音频分析、PCM 解码、键盘通道、插件输入编码、窗口偏好、悬停锁及托盘动画：

```sh
dotnet run --project tests/platforms/windows/CoreTests/Miucs.CoreTests.csproj -c Release
```

Windows 完整构建后，运行 `Miucs.exe --smoke-test build/windows-smoke` 检查插件 Skia 像素输出、托盘和悬停锁。插件状态与传输测试位于 `tests/plugins/`。旧 WPF 可视化和对应场景测试已移除。

可移植测试和交叉编译不能替代 Windows 原生执行。真实 WASAPI、键盘、透明穿透、多屏 DPI、休眠恢复及刷新验收见 [Windows 验收表](../../../docs/windows-acceptance.md)。
