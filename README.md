# Miucs · Pencil Flight

随系统音乐自动飞行的桌面铅笔线稿。当前主旋律决定鸟的目标高度，以短缓动平滑跟随，随机管道在接近时主动避让，起音触发振翅，低中高频分别改变管道笔触、前进速度和尾迹。

```sh
zsh build.sh
```

打开 `dist/Miucs.app`。默认是 400 × 260 的透明、鼠标穿透悬浮画面。菜单栏「画面大小」提供 80%～200% 的预设；选择「调整位置与大小…」可拖动画面移动、拖动右下角连续缩放，完成后选择「完成调整」。尺寸和位置都会保存。也可隐藏、显示或重新连接音频。

应用使用已有的系统音频捕获权限；运行时不依赖 Python、网络服务或外部模型。主旋律是本地近似估计，复杂伴奏可能被误选为主线。

- [画风、映射与验证结果](docs/sound-flight.md)
- [基础音频特征定义](docs/audio-features.md)

验证：

```sh
zsh scripts/test-melody.sh
zsh scripts/test-flight.sh
zsh scripts/validate-audio.sh
```

独立数值参考需要 Python 3、NumPy 和 SciPy；这些仅用于开发验证。
