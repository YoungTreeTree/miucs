# 桌面伙伴的动态预览

GIF 使用同一组「音乐与打字」合成输入，正式 Lua worker 与 Skia CPU 绘制器生成；每张循环 12 秒、采样 16 FPS、最长边 640 像素。暖白背景仅用于预览，应用浮窗是透明的。GIF 无声，不是桌面录屏。

| 插件 | 说明与动态预览 |
| --- | --- |
| **奶牛猫 · 默认主打** | [查看](pixel-keyboard.md) |
| 麦芬 | [查看](../plugins/muffin-puppies/README.md) |
| 牛来 | [查看](../plugins/niulai-keyboard/README.md) |
| 平次与和叶 | [查看](../plugins/heiji-kazuha/README.md) |
| 塞尔达 | [查看](../plugins/zelda-guardian/README.md) |
| 摇曳露营 | [查看](../plugins/yuru-camp/README.md) |

导出于 2026-10-30，随机种子为 42。四个插件使用相同公共输入；尺寸、帧数和时长见[导出清单](assets/plugins/manifest.json)。重新生成的方法见[插件工作台](plugin-lab.md#所有皮肤的统一输入-gif)。

塞尔达提供[独立的 9 秒动画预览](concepts/zelda-guardian/runtime-preview.gif)，依次演示静止、仅键盘、仅音乐、同时输入和停止；未计入上述四插件的统一输入导出清单。

摇曳露营提供[独立的 12 秒动画预览](concepts/yuru-camp/runtime-preview.gif)，依次展示抚子吃面、凛轻啜和节拍篝火；同样使用合成输入与实际渲染器。
