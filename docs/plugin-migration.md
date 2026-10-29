# UI plugin migration

To create your own plugin, start with the [插件开发指南](plugin-development.md). This document covers runtime migration, implementation details and acceptance status.

This change adds a shared Lua + Skia implementation while retaining native renderers as an acceptance baseline. **The plugin path is opt-in until both platforms pass native presentation, latency, performance and sustained-memory acceptance.** The presence of the implementation or a successful build is not evidence that those release gates passed.

## Build and run

Requirements: Python 3.10 with the current security updates (or 3.12), CMake 3.24+, platform C++ toolchain, Xcode/Swift on macOS, Visual Studio C++ build tools and .NET 8 on Windows. Dependencies are downloaded over HTTPS and SHA-256 verified by `scripts/prepare-plugin-deps.py`. First build downloads Lua, nlohmann JSON, matching Skia headers and prebuilt static Skia. Currently supported native dependency targets: Mac arm64, Windows x64 and Windows arm64.

macOS:

```sh
MIUCS_BUILD_PLUGINS=1 zsh build.sh
dist/Miucs.app/Contents/MacOS/Miucs --plugins
```

Windows, from PowerShell with the C++ build tools available:

```powershell
./scripts/build-windows.ps1 -Plugins -Runtime win-x64
./dist/windows/win-x64/Miucs.exe --plugins
```

A build that contains the plugin runtime starts in plugin mode. `MIUCS_PLUGINS=0` or `--no-plugins` keeps the existing renderers; `MIUCS_PLUGINS=1` or `--plugins` forces the plugin path. Plain builds remain usable without fetching Skia. Use `MIUCS_PLUGIN_DEV=1` for file-change reloads, and `MIUCS_FORCE_CPU=1` to exercise CPU fallback. The runtime reports its backend; CPU presentation is capped at 30 FPS. Filesystem plugins do not require application recompilation.

The three built-in IDs (`pencil-flight`, `staff-note`, `pixel-keyboard`) and their window preference keys are unchanged. Each is now an independent folder under `plugins/`, with its own manifest, source and assets. The **可视化** menu lists these plugins directly, including installed user plugins. The application owns the cat logo and tray animation; they do not load a Lua worker and keep working when a plugin fails or is reloaded. Native capture and analysis remain platform implementations; the plugin modules have no capture controls.

## Package layout

```text
plugins/
├── pixel-keyboard/   # pixel music keyboard
├── pencil-flight/    # pencil bird
└── staff-note/       # staff, notes and ripples
```

Each folder can be copied, updated and validated independently. No sibling folder is needed. `apps/assets` holds the application cat portrait and packaged icons; regenerate the `.icns` / `.ico` files on macOS with `python3 scripts/generate-app-icons.py`. The pixel keyboard has its own copy of the portrait for its UI.

## Author a package

```sh
cp -R tools/plugins/template /path/to/my-plugin
# Edit the manifest ID, main.lua, scene.lua and local assets.
python3 tools/plugins/validate.py /path/to/my-plugin
python3 tools/plugins/preview.py --plugin /path/to/my-plugin --output build/my-preview
```

The validator starts the real isolated worker, checks its single UI with synthetic input, decodes resources, and runs lifecycle callbacks. The preview exports PNG files through the same Skia CPU renderer. The manifest declares `id`, `name` and `layout` at the top level; the scene root uses the same `id`. Legacy `visualizations` arrays and `tray` entries are rejected. Both tools use only Python's standard library. See `contracts/plugins/README.md`, `manifest.schema.json` and `api.lua` for the protocol and editor definitions.

Install by copying the complete folder into the platform user plugin directory and choosing the rescan menu action. Active instances survive a failed rescan/reload. Removing a folder removes its entry on rescan; the current already-loaded instance may remain until switched or reloaded. A changed manifest ID is a new package, not an update to the prior identity.

## Source map

| Area | Location |
|---|---|
| Pure scene model, resource validation, Lua runtime | `modules/plugins/src/model.*`, `resources.cpp`, `runtime.*` |
| Worker, bounded binary transport, watchdog | `worker.cpp`, `client.*` |
| Shared Skia painter and C ABI | `renderer.*`, `bridge.cpp`, `include/miucs_plugins.h` |
| Metal / D3D12 + DirectComposition | `surface_mac.mm`, `surface_win.cpp` |
| Platform feature adaptation, package lifecycle, reload | `modules/plugins/platforms/macos`, `modules/plugins/platforms/windows` |
| Physical key names | `modules/keyboard/platforms/*/*PhysicalKeys*` |
| Shared built-in animations and drawings | `plugins/pixel-keyboard`, `plugins/pencil-flight`, `plugins/staff-note` |
| Template, synthetic fixture, validation and previews | `tools/plugins` |
| Worker, transport, replay, native surface and reload tests | `tests/plugins`, `scripts/test-plugin*` |

No third-party native extension ABI, marketplace, automatic download/update, arbitrary shaders or full application-page UI is included.

## Verification commands

```sh
sh scripts/build-plugins.sh
sh scripts/test-plugins.sh
zsh scripts/test-plugin-macos.sh
python3 tools/plugins/fixture.py
build/plugins/plugin-surface-probe build/plugins/miucs-plugin-worker plugins/staff-note build/plugin-fixture.json
MIUCS_FORCE_CPU=1 build/plugins/plugin-surface-probe build/plugins/miucs-plugin-worker plugins/staff-note build/plugin-fixture.json
build/plugins/plugin-benchmark plugins build/plugin-fixture.json
python3 tests/plugins/soak.py --seconds 1800
```

On Windows pass the parent `plugins` directory to the surface probe; it starts a separate worker for each UI. The native probe and worker live under `build/plugins/Release` with `.exe` suffixes. `transport_test.py`, validator and preview select that build layout automatically. `.github/workflows/plugins.yml` builds both native paths and saves preview artifacts; adding a workflow does not mean it has run on the current unpushed branch.

The replay compiles production Swift simulations and checks 600 frames per output against Lua, including head/tail, flight position/scale/angle/score, staff motion, trace commands and ring geometry. Fixtures cover short pitch dropouts, silence, long frame intervals, separate input sessions and audio format changes. Host/worker tests cover bounded scene memory, node count, empty path patches, deterministic seeds, revision resync, bytecode, path escapes, corrupt resources, invalid binary packets, event coalescing and a loop that catches its Lua interrupt. Mac reload tests verify candidate failure preservation and viewport continuity.

`plugin-benchmark` measures script wall time and binary decode + atomic scene application separately after warmup. `plugin-surface-probe` measures CPU time spent in native rendering/submission, **not GPU completion or input-to-photon latency**. The soak uses CPU raster export, switching and worker restarts; its pacing overruns are not a GPU dropped-frame result. Run performance acceptance on otherwise idle, fixed machines with the same Release build, size and DPI as the native baseline.

## Release gates

Track measured local results in `docs/validation/plugin-runtime.md`. Do not remove the old Swift/C# drawing paths or enable plugins by default until all of these are signed off:

- Native Windows D3D12/DirectComposition transparency, resize/DPI, mouse passthrough, layered WPF interaction, suspend/resume and CPU fallback.
- Native macOS transparency, backing-scale changes, mouse passthrough, hidden/resume, GPU loss and CPU fallback.
- Shared fixture state/path agreement and reviewed screenshots on both platforms, including rings' full area and staff reconnection.
- Isolated fixed-machine Release P95 script update and scene application each ≤ 2 ms; GPU completion separately measured, sustained drops < 1%, added input-to-display P95 ≤ one frame.
- Thirty-minute sustained tests on each target, with repeated switching and reload, showing no sustained memory growth after cache warmup.
- No plugin animation timer when the floating output is hidden; the application tray has its own 16 FPS cadence. Errors leave capture, the cat logo and menus available.

The runtime's 50 ms CPU failure ceiling and watchdog are fault isolation limits, not relaxed performance acceptance criteria. Font rasterization and GPU antialiasing may differ slightly across platforms; no pixel-identical promise is made.

Windows presentation notes: the native popup is unowned and kept immediately below the WPF window, because Win32 owned popups are constrained above their owner ([window relationships](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#owned-windows)). The surface handles `WM_NCHITTEST` with `HTTRANSPARENT`; actual cross-process mouse passthrough remains a native acceptance check ([hit-test semantics](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-nchittest)).
