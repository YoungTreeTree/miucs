# Miucs USB 屏幕适配

本文描述本目录的独立 Miucs **整屏 JPEG 固件**，与桌屿的多组件/Lua 固件是两个目标。桌屿板端皮肤由 `MiucsCore` 与桌屿固件配合运行，见 [嵌入指南](../../docs/embedding.md)。使用核心库不需要给桌屿设备刷本目录固件；下文的 1 MiB 检查仅适用于旧整屏固件布局。

面向已经点亮的 **OSPTEK ESP32-P4C5 V1.3 / P4 rev 3.2 + YDP500BT004-V1（720×1280、JD9365）**。macOS 继续运行原来的 Lua/Skia 皮肤、音频分析和键盘输入；ESP32 接收 JPEG 帧并显示，不在板上运行 Lua/Skia。

## 使用

1. 构建 macOS 应用：在仓库根目录执行 `zsh build.sh`，启动 `dist/Miucs.app`。
2. 首次通过板上的 **USB TO UART / CH343 烧录口**更新应用固件。保留已验证的屏幕排线方向和现有 bootloader。
3. 将数据线改接板上的 **原生 USB 2.0 Type-C 数据口**。Type-C / USB-A 选择开关应选择 Type-C；CH343 口不传输动画。
4. 在「设置 → 硬件屏幕」打开开关。应用只自动识别产品名为 `Miucs P4 Display` 的设备，通过握手后开始传图。
5. 在设置里选择竖屏、横屏或各自反向。无需重新烧录。当前皮肤同步到屏幕；隐藏桌面皮肤后，硬件仍继续运行。

画面保持比例，浅色背景，居中并保留至少 16 像素边距。发送上限为 20 帧/秒，实际帧率由渲染、USB 和屏幕回执决定，设置中显示实测值。未连接时等待自动重连；连接中断时屏幕保留最后一帧。USB 传输只包含渲染好的皮肤画面。

## 构建固件

使用 ESP-IDF **v5.5.6**；组件版本固定在 `dependencies.lock`。ESP-IDF 和工具链不放入仓库。

```sh
export IDF_PATH=/absolute/path/to/esp-idf
export IDF_TOOLS_PATH=/absolute/path/to/esp-idf-tools
zsh scripts/build-hardware.sh
```

输出为 `hardware/esp32-display/build/miucs_display.bin`。此固件的芯片最低版本为 P4 rev 3.1，不适用于早期 P4 芯片。

本板先前启动测试使用了 `esp-idf-v5.5.6-osptek-startup.patch`，针对 rev 3.2 在 bootloader 调频前增加 5 ms 等待。这是本板的临时启动修正，**本次更新只写应用分区，不覆盖已经可用的 bootloader**。如重新构建并写入启动程序，需单独核对该补丁，不能把普通开发板的全量烧录命令直接当作本板验收结果。

## 烧录与回退

在已安装 `esptool` 的 Python 环境运行：

```sh
python scripts/hardware/flash.py --port /dev/cu.YOUR_CH343_PORT
```

脚本先读取分区表，确认 factory 应用在 `0x10000`、容量 1 MiB，再备份当前应用，最后写入新固件。备份位于 `build/hardware-backups/<时间>/`，包含原应用、分区表和 SHA-256 记录。脚本限定 ESP32-P4 和已验证的分区布局，布局不匹配时停止。

回退到备份应用：

```sh
python -m esptool --chip esp32p4 --port /dev/cu.YOUR_CH343_PORT --baud 115200 --no-stub \
  write-flash 0x10000 build/hardware-backups/TIMESTAMP/previous-app.bin
```

## 传输协议 v1

设备通过原生 USB High-Speed CDC-ACM 枚举，产品名 `Miucs P4 Display`，日志仍走 UART。原生 CDC 的 line-coding 波特率不限制 USB 数据传输速率。没有安装屏幕固件时，应用不会尝试向其他串口发送图片。

空闲设备每秒发送：`MIUCS_DISPLAY 1 720 1280 262144\n`。

主机发送 24 字节小端头，后接 JPEG：

| 偏移 | 字段 | 约束 |
| --- | --- | --- |
| 0 | magic，4 字节 | `MIUC` |
| 4 | version，u8 | 1 |
| 5 | type，u8 | 1 = JPEG |
| 6 | reserved，u16 | 0 |
| 8 | sequence，u32 | 回执关联 |
| 12 | payload length，u32 | 4…262144 |
| 16 | payload CRC-32，u32 | IEEE / zlib，初始与最终异或 0xffffffff |
| 20 | width，u16 | 720 |
| 22 | height，u16 | 1280 |

方向在主机旋转合成时处理，因此 JPEG 总是 720×1280。固件校验尺寸及 CRC，用硬件 JPEG 直接解码到 RGB565 双缓冲，省去整帧 CPU 颜色转换。每次启动的首帧会与 BGR888 参考路径逐像素校验字节顺序，之后释放参考缓冲。USB 接收和端点缓冲均为 8 KiB，CRC 使用按字节查表。等待 DMA 边界后回执：`MIUCS_ACK <sequence> <esp_err_t> <处理毫秒>\n`，状态 0 表示显示提交完成。

只有一帧处于发送/等待回执阶段，不缓存过期动画。主机遇到写入失败、3 秒超时或错误回执会关闭连接并重试。设备丢弃断线及超过 2 秒未接收完整的包，并能跳过无效头重新同步。

## 验证范围

```sh
zsh scripts/test-hardware.sh
zsh scripts/test-plugin-macos.sh
zsh scripts/test-settings.sh
```

已覆盖：实际 Swift 串口代码与伪终端之间的分片握手/回执、超时和断线；C 接收解析器的分片/噪声/超限/CRC/重连（ASan、UBSan）；四种方向的 JPEG 输出；七个真实皮肤导出；隐藏桌面后的 worker 生命周期；热重载后导出缓存失效；设置窗口和原有皮肤切换回归。

**实机验证（2026-11-09）**：已备份原应用并烧录本版，保留 bootloader；原生 USB 枚举、七种皮肤 JPEG 解码、错误 CRC 拒绝及断开后的握手重连通过。使用同一组七张测试图片连续发送 20 秒，完成 330 帧（16.46 帧/秒），平均板端显示处理 35.8 ms。首帧 RGB565 与参考路径的 921,600 像素校验误差为 0；日志未出现 panic 或任务栈溢出。此测试使用预编码图片，不代表所有皮肤的实时动画帧率，也不是长时间耐久测试。实际应用中「摇曳露营」测得约 14.5 帧/秒、167 KiB/帧，板端处理约 34 ms；音乐及键盘输入已连接，用户实测确认动画明显顺滑、可以接受。

实机探测使用生产传输代码。先关闭应用的硬件开关以释放串口，再运行：

```sh
zsh scripts/probe-hardware.sh --seconds 20 --output build/hardware-live-probe.json
```

测试完成后重新打开硬件开关即可恢复实时动画。 当前版本不转发触摸事件，也不将外接键盘插到开发板上；键盘与音乐来自电脑现有输入链路。Windows 宿主尚未接入此传输功能。

## 来源

- [OSPTEK 屏幕资料及示例](https://github.com/osptek/display-tft-5inch-720x1280)：`main/jd9365_init_cmds.h` 和 DSI 初始化时序源自厂家示例，沿用 CC BY 4.0，版权归 OSPTEK 鱼鹰光电；许可副本见 `OSPTEK-LICENSE.txt`。本适配增加了 USB 帧传输、双缓冲和动态 JPEG 显示。
- [OSPTEK 开发板资料](https://github.com/osptek/devboard-esp32p4c5_module)。
- [Espressif USB Device Stack](https://docs.espressif.com/projects/esp-usb/en/latest/esp32p4/usb_device.html)。
