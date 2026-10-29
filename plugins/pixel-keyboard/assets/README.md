# Built-in visual assets

- `cat-head.png` is copied unchanged from `modules/visualizations/pixel-keyboard/assets/cat-head.png` in this repository.
- `tail-atlas.png` is generated deterministically from the existing `PixelTailSprite` geometry by `python3 tools/plugins/generate_tail_atlas.py`. It contains 257 poses on a 16-column 96×88 pixel grid, rendered with nearest-neighbor sampling.
- `NotoSans-Regular.ttf` is the Noto Sans font from the Noto project (`notofonts/noto-fonts`, hinted/ttf/NotoSans/NotoSans-Regular.ttf). Its SIL Open Font License is in `OFL.txt`. It is bundled to keep both platforms on the same font file.

Native runtime notices are shipped separately in `third_party/plugin-licenses`.
