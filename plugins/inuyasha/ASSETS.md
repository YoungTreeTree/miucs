# 绘制资源

全部角色图集和背景通过内置 imagegen 生成。角色参考用户确认的概念图；用户后续指定去掉对白，因此运行时只包含动作与键帽标签，不包含「坐下！」文字、对白气泡或音效字。

| 文件 | 内容 | 最终生成提示词 |
| --- | --- | --- |
| `assets/inuyasha.png` | 1254×1254 RGBA；16 帧逞强、扑地、恢复 | [犬夜叉](../../docs/concepts/inuyasha/inuyasha-prompt.txt) |
| `assets/kagome.png` | 1536×1024 RGBA；12 帧待机和指地 | [戈薇](../../docs/concepts/inuyasha/kagome-prompt.txt) |
| `assets/shippo-dust.png` | 1448×1086 RGBA；8 帧七宝与石头、4 帧尘土 | [七宝与尘土](../../docs/concepts/inuyasha/shippo-prompt.txt) |
| `assets/backdrop.png` | 2172×724；御神木与村落的静态全景 | [背景](../../docs/concepts/inuyasha/backdrop-prompt.txt) |

[注册工具](../../tools/plugins/register_inuyasha_frames.py)查找各格间的透明间隔和脚底/石头底部接触带，生成 sourceRect、固定像素比例、绘制偏移和[注册记录](../../docs/concepts/inuyasha/frame-registration.json)。所有 PNG 保留生成原像素，不逐帧拉伸、旋转或镜像，不通过插值变形伪造角色动作。背景等比放大后在舞台范围裁切。

`keys.lua`、`ink.lua` 和键盘输入消费逻辑来自现有插件；边框与按键为静态程序绘制 UI。Noto Sans 字体沿用 `OFL.txt` 的 SIL Open Font License。犬夜叉、日暮戈薇和七宝为《犬夜叉》的角色，本皮肤为非官方主题创作。
