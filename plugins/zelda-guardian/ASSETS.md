# 资源来源

- 视觉依据：`docs/concepts/zelda-guardian/skin-concept-v2.png`，用户确认的第二版设计。第一版仅作产品图。
- `assets/link-actions.png`：内置 imagegen 生成，RGBA，16 帧。前 8 帧挥剑，后 8 帧举盾／盾反。最终留白修正版提示词：`docs/concepts/zelda-guardian/link-actions-prompt.txt`；最初草稿保留在概念目录。
- `assets/guardian-beat.png`：内置 imagegen 生成，RGBA，16 帧。1 静止，2–8 蓄能，9–12 发射后坐，13–16 复位。提示词：`docs/concepts/zelda-guardian/guardian-beat-prompt.txt`。
- `assets/typing-hands.png`：内置 imagegen 生成，RGBA，8 帧，两手各四态。模型将第四列左右手画反，注册表交换两格，保留原像素。提示词：`docs/concepts/zelda-guardian/typing-hands-prompt.txt`。
- `frames.lua` / `docs/concepts/zelda-guardian/frame-registration.json`：由 `tools/plugins/register_zelda_frames.py` 生成的源区域、地面／袖口锚点和眼睛／盾牌落点。脚本只读原始 PNG 元数据，不修改图像。源区域不等大，渲染时使用固定像素缩放和固定世界锚点，避免每帧拉伸和跳位。
- `assets/NotoSans-Regular.ttf` / `OFL.txt`：沿用现有插件字体及 SIL Open Font License。
- `keys.lua`、`ink.lua` 和键盘输入处理沿用项目现有实现；新增配色和希卡风格简线纹饰由代码绘制。

这是用户要求的非官方塞尔达主题皮肤；林克与守护者为现有 IP 角色，生成素材不表示获得原 IP 的商业授权。
