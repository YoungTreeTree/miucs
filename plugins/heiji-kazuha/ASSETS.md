# 资源与来源

- [确认的皮肤概念图](../../docs/concepts/heiji-kazuha/skin-concept.png)：在现有像素键盘皮肤上通过内置 imagegen 迭代，采用用户确认的平次/和叶布局及靛蓝、奶油白、浅绿、樱粉配色。用于设计参考，运行时不加载概念图。
- `assets/heiji-swing.png`：内置 imagegen 生成的 1536×1024 RGBA 木剑动作图集，4 列 × 3 行，共 12 帧。[完整生成提示词](../../docs/concepts/heiji-kazuha/heiji-prompt.txt)。
- `assets/kazuha-turn.png`：内置 imagegen 生成的 1536×1024 RGBA 转身图集，4 列 × 2 行，共 8 帧。[完整生成提示词](../../docs/concepts/heiji-kazuha/kazuha-prompt.txt)。弃用的第一组转圈图集未打包。
- 以上 PNG 原样保存，未重新绘制、抠图或缩放。`tools/plugins/register_heiji_kazuha.py` 只读取透明通道，测量姿态边界与脚底锚点，生成 `frames.lua`；[配准记录](../../docs/concepts/heiji-kazuha/registration.json)包含原图 SHA-256、源区域和锚点。运行时按统一像素比例绘制每个角色的帧，足底对齐；不对单帧做独立拉伸。
- `assets/NotoSans-Regular.ttf`、`assets/OFL.txt` 复制自现有像素键盘插件，字体使用 SIL Open Font License。
- `keys.lua` 和键盘轮廓沿用项目现有像素键盘布局；输入校验参照麦芬插件。键盘和短暂音符通过 Lua 场景绘制，角色动作来自图集。

服部平次和远山和叶为《名侦探柯南》角色，本插件为用户要求的非官方皮肤。生成资产不代表获得原角色的商业授权。
