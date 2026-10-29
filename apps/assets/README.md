# Application identity

`cat-head.png` is the existing Miucs cat portrait, copied unchanged from the pixel-keyboard artwork. The shell uses it for the application logo and tray in every visualization mode, independently of plugin loading and Lua workers.

`Miucs.icns` and `Miucs.ico` are generated from this portrait by `python3 scripts/generate-app-icons.py` on macOS. The pixel-keyboard plugin carries its own asset copy so it remains independently installable.
