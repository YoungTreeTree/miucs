# 资源与来源

- `assets/characters.png`：根据用户确认的 `docs/concepts/muffin-puppies/skin-concept-v3.png`，用内置 imagegen 生成的 1536×1024 透明六格图集。原图未改写，运行时 `sourceRect` 为各姿态按脚底配准。生成提示词在同目录概念资料 `sprite-prompt.txt`。
- `assets/maltese-jump-v3.png` 与 `assets/golden-jump-v3.png`：内置 imagegen 各绘制 16 帧跳跃，1254×1254 RGBA 原图。跳跃高度、姿态变化与阴影直接画在帧中。`jump_frames.lua` 保存每只狗各自固定大小的源区域（马尔济斯 300×295，小金毛 300×280）；`tools/plugins/register_muffin_jump.py` 读取原图的灰色地面阴影作对齐标记，不修改任何像素。当前两只狗使用这两张新图集，`characters.png` 仅用于麦芬。提示词见 `docs/concepts/muffin-puppies/jump-prompts.txt`。
- 麦芬、马尔济斯与小金毛是现有 IP 角色；本插件是用户要求的非官方皮肤设计，生成图片不表示获得原 IP 的商业授权。角色参考来源见 `docs/concepts/muffin-puppies/prompt-v2.txt`。
- `assets/NotoSans-Regular.ttf` 与 `OFL.txt` 沿用现有像素键盘包，使用 SIL Open Font License。
- 键位表沿用项目现有布局；键盘、双爪、断续描边与泡泡是本插件的缓存路径绘制，不依赖概念图整图贴图。
