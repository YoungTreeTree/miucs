# 资源与生成提示词

所有位图均使用内置 imagegen 生成，启用真实透明背景；以用户确认的[概念图](../../docs/concepts/yuru-camp/skin-concept-v1.png)为造型参考。

| 素材 | 内容 | 最终提示词 |
| --- | --- | --- |
| `assets/nadeshiko-eat.png` | 抚子与完整折叠椅，12 帧吃面，1448×1086 RGBA | [提示词](../../docs/concepts/yuru-camp/nadeshiko-eat-prompt.txt) |
| `assets/rin-sip.png` | 凛与完整折叠椅，12 帧喝茶，1448×1086 RGBA | [提示词](../../docs/concepts/yuru-camp/rin-sip-prompt.txt) |
| `assets/camp-props.png` | 前 8 格篝火，后 8 格双色手套，1254×1254 RGBA | [提示词](../../docs/concepts/yuru-camp/camp-props-prompt.txt) |

`tools/plugins/register_camp_frames.py` 根据椅脚、火盆脚、袖口的可见像素读取固定锚点，输出 `frames.lua` 和 [注册数据](../../docs/concepts/yuru-camp/frame-registration.json)。不改写 PNG，不重新采样，不按每帧包围盒拉伸角色。模型将两只手套的最后一格画成相反方向，渲染时对这两格固定镜像并保持袖口位置；不借此合成压键动作。

`keys.lua`、`ink.lua` 与键盘输入处理复用现有插件结构。`assets/NotoSans-Regular.ttf` 和 `assets/OFL.txt` 沿用 SIL Open Font License 字体。

这是用户要求的非官方《摇曳露营》主题皮肤。抚子与志摩凛为现有 IP 角色，生成素材不表示获得原 IP 的商业授权。
