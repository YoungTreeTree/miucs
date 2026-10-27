# 打字驱动的像素猫头

`typing-head-preview-v1.gif` 为 5 秒循环、150 帧的三档速度对比，使用应用实际的 `PixelHeadScene` 和原有 `cat-head.png` 绘制。每秒 1、2、4 次普通按键分别对应每秒 0.4、0.8、1.6 次摇头；摆幅均为 ±12°，下巴支点固定。下方色条模拟按键时间。它不是真实桌面输入录像。

应用实现包含起停过渡、按键速度平滑、重复与修饰键排除、权限与生命周期复位；这里先预热到稳定速度，以便直接比较节奏。超过每秒 6 次按键时限制为 2.4Hz，避免抖动。

`exploratory-poses-v1.png` 是内置 imagegen 参考图编辑模式生成的探索分镜，完整提示词见 `prompt-v1.txt`。生成帧的五官与角度存在轻微变化，因此最终预览和应用均使用原有猫头的旋转变换，不播放该分镜，不替换原有头像素材。

从仓库根目录重新生成预览：

```sh
swiftc -swift-version 6 -parse-as-library -O -framework AppKit \
  modules/keyboard/core/*.swift \
  modules/visualizations/pixel-keyboard/core/PixelHeadScene.swift \
  docs/concepts/pixel-cat-head/render-preview.swift -o build/pixel-head-preview
build/pixel-head-preview
```
