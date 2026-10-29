# UI plugin API v1

Miucs keeps platform capture and analysis unchanged. A package consumes immutable feature snapshots in a Lua 5.4 worker and publishes scene changes. The shared C++ host applies complete revisions and draws with the pinned Skia build. No capture implementation, OS window, PCM, text input, network or filesystem handle enters Lua.

## Package and lifecycle

Copy `tools/plugins/template` to a new folder and change the top-level `id` and the matching scene root ID. One folder is one UI: `id`, `name` and `layout` belong directly to the manifest, and the **可视化** menu is the plugin selector. `visualizations` arrays and `tray` declarations are rejected. `manifest.schema.json` describes metadata; the native validator additionally checks containment, unique IDs and `minimumWidth <= width <= maximumWidth`. The folder contains a UTF-8 JSON manifest, Lua source and any local assets. IDs may contain ASCII letters, digits, `.`, `_`, `-`, up to 128 bytes.

`entry` returns a lifecycle table. All callbacks are optional. The host calls `create({api=1,seed=1})`, `activate(viewport)`, `update(frame)`, `resize(viewport)`, `appearanceChanged(appearance)`, `deactivate()` and `dispose()`. Cleanup must be idempotent. Normal close schedules a bounded dispose and teardown off the UI thread; a worker monitors its host process and exits if the host disappears. An abruptly killed worker cannot run cleanup; external resources remain owned by the host. One selected package has one worker and one floating output. Switching plugins disposes the previous worker. Hiding the output stops plugin updates; resuming uses fresh subscriptions. The cat logo and tray are application-owned and independent of all plugins.

API definitions for Lua language servers are in `api.lua`. Add this directory to the editor's Lua workspace library; do not load that file from a plugin.

`miucs.load(table)` builds a persistent tree and returns no value. String IDs are stable node handles. `miucs.set(id, table)` patches properties; `id`, `type`, `parent` and `children` cannot change. An empty path clears it. Reuse nodes, update transforms for sprites, and bound dynamic paths. The runtime publishes changed properties only; native path caches rebuild only when geometry changes. A `pathRef` names another concrete path node, sharing its cached geometry across many drawings. Update the referenced path once with `miucs.set` to change every consumer; ring arcs and stars use these reusable buffers. References cannot chain. There is no append API: a changed buffer replaces its bounded command value.

`miucs.require("scene.lua")` loads a source file once within this package. Only `.lua` text is accepted. Absolute paths, parent traversal, NULs and symlink escapes are rejected. On macOS resource traversal rejects all symlinks; Windows checks the final opened file handle against the package root. No Lua bytecode or native libraries are accepted. `miucs.random()` returns seeded deterministic values; host workers currently start at seed 1, and C++ replay tools may construct a runtime with another seed, or launch the worker with `--seed 42`.

## Scene rules

Coordinates are logical units, origin top-left, x right, y down. Rotation is clockwise radians. Transform order is translation, normalized pivot, rotation, scale, inverse pivot. An optional six-element `matrix={a,b,c,d,tx,ty}` replaces rotation/scale for affine transforms such as an elliptical ring rotated before its y compression. Root width/height define the design space; the host fits it uniformly into the physical target from the top-left. Width, height and scale in viewport callbacks describe the host viewport, not a replacement design space.

Nodes: group, path, image, text, rect, ellipse. A path uses M/L/Q/C/Z commands; all arguments must be finite. Siblings draw in ascending `z`, then declaration order. Composition uses premultiplied alpha and source-over; group opacity isolates a layer. `clip` is a local rectangle. Linear `gradient` fills and gradient `mask` alpha are supported. Arbitrary path clips, blend modes and shaders are not public v1 APIs.

Stroke defaults to round caps/joins and scales with transforms. `constantStroke` compensates the node's own x scale; ancestor/output scaling still applies. A stroke replaces the fill paint; use two nodes when both are needed. Image atlas rectangles are in source pixels; `nearest` preserves pixel art. Text requires a bundled font, uses a baseline, and draws simple UTF-8 glyphs. Complex-script shaping/layout is not implemented. Redistribute fonts only under their license.

## Inputs and clocks

Audio fields retain `../audio-features/input.schema.json`. Keyboard retains the existing keyboard contract, replacing platform `keyCode` with a stable physical `key` string. Unknown physical keys are nil, never inferred from typed text. Mac Option/Command map to `leftOption`/`leftCommand`; Windows Alt/Windows use those same physical identities. Right variants are separate. Fn is available only when the OS reports it. The mappings live in the keyboard platform adapter, not plugins.

Audio and keyboard have independent session IDs, sequence cursors, ages and loss counters. A new session invalidates that input's cursors only. `now`, `receivedAt`, `sampledAt` and `deltaTime` use host monotonic seconds. `audio.time`, melody and beat analysis times use the audio timeline. Never subtract across timelines. The host's elapsed delta may be long after a stall; plugins should settle rather than replay missed frames.

The host grants data only through its existing audio/keyboard enablement and OS permissions. The worker additionally strips inputs absent from `manifest.inputs`. Sources use independent subscriptions, preserving capture thread isolation. A pending frame keeps the newest continuous snapshot, merges ordered discrete events (128 keys, 64 beats, 64 onsets), expires events beyond 250 ms and increments drop counts. Audio flux is merged only within a session. No pending events survive suspend/resume resubscription.

## Wire and failure handling

C ABI: `modules/plugins/include/miucs_plugins.h`. Host calls are on the UI thread; `post` queues bounded messages and does not wait for Lua. A dedicated I/O thread writes length-prefixed MessagePack over anonymous pipes. Framing is a 4-byte little-endian length, then one MessagePack object (maximum 2 MiB, nesting 24). Worker input is `{op,value,ack}`. Reply is `{ok,scene,updateMs,luaBytes}` or `{ok=false,error}`. Metrics are diagnostic, not GPU time.

Scene packets contain `full`, `base`, `version`, `nodes` and `removed`. Nodes in a delta are property patches. Full snapshots replace state. The runtime emits a full snapshot when acknowledgement differs from its current version; the host applies revisions atomically. Only input frames coalesce; published scene deltas are acknowledged in order. The UI takes the newest complete snapshot with a nonblocking lock attempt and may keep the previous scene for a frame.

Limits: 32 MiB Lua allocator, 16 MiB estimated retained scene storage, 4,096 nodes, 16,384 path commands per node, 1 MiB source file, 16 MiB encoded image file, 4 MiB font file, 4,096 px image dimensions, 64 MiB decoded image cache per surface, 16 cached fonts, 16 million target pixels. Calls have a 50 ms worker-thread CPU failure ceiling (100 ms activate; 250 ms create); that ceiling is separate from the 2 ms P95 performance target. Lua instruction hooks enforce deadlines, and a host watchdog kills a worker that catches its hook errors or stalls in native code (500 ms request / 1,500 ms startup).

Lua exposes base/math/string/table/utf8, with dynamic loading, file access, print, collectgarbage and nondeterministic random APIs removed. Independent workers provide failure isolation; they are **not** an OS security sandbox. Skia resource decoding stays in the rendering host with size limits. Invalid resources disable the package. Parser/renderer vulnerabilities are not ruled out by the Lua capability restrictions.

## Installation and reload

- macOS user root: `~/Library/Application Support/Miucs/Plugins`.
- Windows user root: `%LOCALAPPDATA%\Miucs\Plugins`.
- Copy a package folder, then choose **重新扫描插件** / **重新扫描** in the menu.
- Duplicate plugin IDs are errors. Built-ins are scanned first and cannot be overridden by user folders. Scanning does not execute scripts.
- **重新加载当前插件** starts a candidate worker, invokes lifecycle callbacks and verifies its first CPU-rendered frame. Only a successful candidate replaces the live worker; failure retains the old one. Window and appearance preferences stay in the host; animation state resets.
- `MIUCS_PLUGIN_DEV=1` polls active package file metadata once a second for development reloads. No online installer/updater is involved.

See `docs/plugin-migration.md` for build commands and acceptance status.
