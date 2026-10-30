# Miucs · 奶牛猫桌面伙伴

**打字时伸爪，听音乐时摇尾。**

奶牛猫是 Miucs 的默认桌面伙伴：黑白猫爪跟随按键，猫头随打字轻晃，尾巴响应音乐节拍。画面透明、默认鼠标穿透，不抢键盘焦点。

`macOS 14+ · Apple Silicon · Swift 6` · `Windows 10/11 · 实机待验`

![奶牛猫：猫爪跟随打字，猫头与尾巴响应输入](docs/assets/plugins/pixel-keyboard.gif)

> 预览使用合成音乐与按键输入，经正式 Lua/Skia 绘制器生成；GIF 无声，不是桌面录屏。

## 五个桌面伙伴

| 插件 | 效果 | 详细说明 |
| --- | --- | --- |
| **奶牛猫 · 默认主打** | 黑白猫爪敲键、猫头轻晃、尾巴随节拍摆动 | [奶牛猫](docs/pixel-keyboard.md) |
| 麦芬 | 两只线条小狗随打字跳跃，麦芬随节拍吹泡泡 | [麦芬](plugins/muffin-puppies/README.md) |
| 牛来 | 牛蹄响应按键，上方角色随音乐和打字运动 | [牛来](plugins/niulai-keyboard/README.md) |
| 平次与和叶 | 平次随打字挥木剑，和叶随节拍转身 | [平次与和叶](plugins/heiji-kazuha/README.md) |
| 塞尔达 | 林克随按键挥剑、举盾，守护者随拍点发射激光 | [塞尔达](plugins/zelda-guardian/README.md) |

[查看五个插件的动态预览](docs/plugin-previews.md)。首次启动默认选择奶牛猫；之后记住你的选择。每个插件分别保存位置和大小，切换不重启输入采集。

## 构建与启动

### macOS

需要 Apple Silicon、macOS 14+、Swift 6、Python 3.10+、CMake 3.24+；首次本地开发签名需要 OpenSSL 3。

```sh
zsh build.sh
open dist/Miucs.app
```

首次运行按提示授权系统音频捕获；要让猫爪响应打字，授予「输入监控」权限。音频和键盘可以同时使用，也能独立运行。系统休眠或音频中断后自动恢复，也可在菜单选择「重新连接音频」。更新后先退出旧版，再打开新构建。

### Windows

提供 .NET 8/WPF、WASAPI 实现。构建方法见 [Windows README](apps/windows/README.md)，实机验证范围见 [验收表](docs/windows-acceptance.md)。

## 常用操作

- **可视化**：切换五个桌面伙伴，奶牛猫排在首位。
- **显示 / 隐藏画面**：控制浮窗显示。
- **画面大小、不透明度**：等比缩放，调整 10%～100% 不透明度。
- **调整位置与大小**：拖动画面或右下角缩放，完成后恢复鼠标穿透；也可悬停 3 秒点击小锁。
- **托盘猫摇头**：应用自己的猫图标，独立于当前插件。

## 插件与隐私

应用内置五个 Lua 5.4/Skia 插件，也可安装自己编写的插件。首次构建自动下载并校验运行库依赖。开发和调试见 [插件开发指南](docs/plugin-development.md) 与 [插件工作台](docs/plugin-lab.md)。

音频与物理按键只在本机分析，不依赖网络模型；应用不保存真实音频、屏幕或输入文字。

## 开发文档

- [贡献指南与测试](CONTRIBUTING.md) · [架构与依赖边界](docs/architecture.md)
- [插件契约](contracts/plugins/README.md) · [可视化契约](contracts/visualization/README.md)
- [音频数据](contracts/audio-features/README.md) · [键盘数据](contracts/keyboard-input/README.md)
- [外观设置](docs/appearance.md) · [验证记录](docs/validation/README.md)
