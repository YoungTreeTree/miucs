# 像素猫尾巴：概念与动作参考

确认的 v2 概念已转为奶牛猫插件的尾巴图集和 Lua 节拍动画，保持固定尾根和稳定粗细，并由实际拍点驱动。生产实现与灵敏度参数见[奶牛猫说明](../../pixel-keyboard.md)，实际原生合成演示见[主页 GIF](../../assets/miucs-pixel-keyboard.gif)。以下保留设计过程及生成提示词。

## v2：收细与循环预览

按反馈将尾巴收细，保留圆钝尾尖和黑色毛边。使用内置 imagegen 的参考图编辑模式生成透明 4×4 动作表，提示词见 `prompt-v2.txt`。

- `motion-slim-sprites-v2.png`：16 帧透明原图。
- `tail-motion-v2.gif`：640×400 循环动画预览，每帧 80ms，一轮 1.28 秒。
- `assemble-preview.swift`：裁切原图、统一两倍缩放、按尾根配准并编码 GIF；不重新绘制造型。

这是动作概念预览，不是应用直接播放的精灵表。生成帧仍有轮廓和长度的轻微变化；生产实现已用固定几何和连续相位重建。此预览按固定速度播放，不接入实际音乐节拍。

重新组装：在仓库根目录执行 `swift docs/concepts/pixel-cat-tail/assemble-preview.swift "$PWD/docs/concepts/pixel-cat-tail"`。

## v1：初始概念

2026-10-27，根据当时应用界面生成。使用内置 imagegen 工具；该设计阶段未修改或重启运行版本。

- `ui-concept-v1.png`：整体布局。保留猫头、键盘、双爪和屏幕中间留白，只替换右侧尾巴。
- `motion-16-frames-v1.png`：一轮完整的 16 帧概念分镜，按行从左到右阅读，16 回接 01。
- 造型方向：横向、纯黑、厚实尾根、宽厚尾身、圆钝尾尖、少量像素毛边。避免细线和尖锐长锥形。
- 动作方向：尾根固定，中段带动尾尖，微小滞后与缓慢换向；节拍控制循环速度。

这些是 AI 绘制的设计参考，不是已配准的生产精灵图。开发时需统一根部锚点、包围盒、尾巴长度和体积，并检查每帧衔接；不能直接裁图播放并宣称已验证自然动作。

## 最终提示词：整体概念

Use case: precise-object-edit. Edit target: the supplied screenshot of the Miucs pixel keyboard. Create one finished UI concept image. Preserve the ENTIRE keyboard, keys, lettering, two white-mitten black cat paws, cream display, lavender frame, LEFT cat portrait, empty center, proportions and positions exactly. Change ONLY the tiny black tail in the RIGHT side of the upper screen. Replace the thin rat-like line with an unmistakable plush BLACK HOUSE CAT TAIL in coarse hand-drawn pixel art. Horizontal, root on LEFT at same height as cat head center, rounded tip to the RIGHT curving gently upward. Proportions at the screenshot's 800px width: tail total length about 76px, base thickness about 18px, shaft thickness 15-17px over most of its length, rounded blunt tip about 12px thick, max vertical extent 32px. Solid pure black fill, NO highlights, NO gray, NO pink, NO stripes, NO skinny taper, NO sharp tip. A few understated stepped pixel tufts on the silhouette make it furry, but NOT spiky and NOT a fox plume. It should read as a soft substantial cat tail, not a worm, rat tail, thin cable, stroke, eyebrow or check mark. Crisp 2px block stair-step edges, elegant simple slightly curved silhouette; root stays near x660, tip near x736, centered near y86. Head stays 64px. No cat body. Do not add a green box, staff, notes, particle effects, labels, arrows, annotations or anything in the empty center. Full uncut UI on plain light background, same composition as reference.

## 最终提示词：16 帧分镜

Use case: stylized-concept. Create a production concept STORYBOARD / SPRITE POSE SHEET for the BLACK CAT TAIL shown at the upper RIGHT of the supplied UI concept. The reference is for tail identity, silhouette, pixel style and thickness ONLY. Do not draw the keyboard, paws, face, screen, body or any other objects. Deliver ONE large clean sheet with EXACTLY 16 equal cells in a precise FOUR columns by FOUR rows grid. Reading order is left-to-right, top-to-bottom, labeled exactly 01 02 03 04 / 05 06 07 08 / 09 10 11 12 / 13 14 15 16. Each cell contains ONE enlarged isolated PURE BLACK plush house-cat tail, horizontal root at left and rounded blunt tip at right, identical scale and identical root position in all cells. Cream background, very faint lavender dividers, small gray frame numbers. Tail about 76 logical pixels long, base 18 pixels thick, shaft 15-17px most of length, rounded tip 12px thick. Flat #000000 only, no shading/highlight/outline color. Broad furry cat silhouette with a few restrained stepped pixel fur notches; chunky crisp pixel art, NOT thin rat tail, cable, worm, pointed whip, fox plume or leaf. Preserve length, volume, root and thickness across all frames. Draw all 16 actual consecutive animation poses for ONE smooth seamless relaxed swish loop, NOT alternative designs. The root's first 10 percent never moves. The middle gently rises then falls, and the rounded tip follows a couple of frames later, with elastic soft curvature, subtle natural S bends rather than a stiff rotated rod. Overall stays horizontal; no extreme coils, no tight curls, no vertical upright poses. Exact sequence: 01 relaxed slightly raised tip; 02 mid begins rising tip lags; 03 mid rises more; 04 raised middle tip follows upward; 05 crest held softly; 06 middle starts lowering while tip remains raised; 07 middle crosses neutral tip follows; 08 middle slightly low tip just above neutral; 09 lowest relaxed wave; 10 tip follows downward while middle starts recovery; 11 middle rises from low and tip still lags below; 12 crosses neutral; 13 slight upstroke, tip recovers; 14 gentle final upward follow-through; 15 easing toward starting curve; 16 nearly returns to frame01 so 16-to-01 is seamless. The motion amplitude is small about plus/minus 10 logical pixels, not big dramatic waving. Each image must be clearly distinguishable as a carefully in-betweened frame while retaining the same cat tail anatomy. No motion blur, onion skins, duplicate tails, ghosting, arrows, unnecessary decorations. All 16 numbered cells must be fully in the image with generous margins.
