# Native plugin runtime notices

Dependency versions and SHA-256 checksums are pinned in `scripts/prepare-plugin-deps.py`.

- Lua 5.4.8: Lua.org / PUC-Rio, MIT.
- nlohmann/json 3.12.0: Niels Lohmann, MIT.
- Skia: rust-skia binary release 0.156.0 and matching source commit 0746a1afaf750159e1a6aef29992980f4e293585, BSD-3-Clause.
- Skia dependencies represented here include libjpeg-turbo/IJG, libpng, zlib, Wuffs, Expat, HarfBuzz, ETC1 and skcms. They are redistributed unmodified; source revisions follow the pinned Skia DEPS file. Some unused objects may be removed by the static linker.
- Noto Sans font: the complete SIL OFL is distributed with the plugin in each `plugins/*/assets/OFL.txt`.

This software is based in part on the work of the Independent JPEG Group.
