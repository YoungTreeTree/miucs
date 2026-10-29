# Plugin implementation validation — 2026-10-29

The implementation is available behind `--plugins` / `MIUCS_PLUGINS=1`. Default rendering remains native until the cross-platform release gates pass.

## Completed locally

Environment: Apple M4, macOS 26.6.2; CMake Release (`-O3`), Swift `-O`, .NET Release. The native application bundle builds and signs with the worker, shared library, built-in package, font and dependency notices.

- 22 native core assertions: manifest/path validation, revision resync, atomic scene application, empty dynamic paths, deterministic seed, repeated dispose, node and aggregate scene budgets, restricted libraries, memory ceiling, bytecode and loop interruption.
- 68 process/transport assertions, including a shared path update invalidating the cached output, 50 queued updates, preserving input across an appearance control, a loop that catches Lua timeout errors, malformed/deep MessagePack, corrupt images a symlink escape and a missing host process.
- 600-frame production Swift reference replay for each built-in output. Head, tail atlas selection, staff position/scale/opacity/sway and ring positions/rotations match exactly; flight state maximum absolute error was `1.734723475976807e-18`. Trace command types, count and coordinates agree within `1e-8`. Fixtures include pitch dropouts, silence, a long frame interval, independent input reconnection and audio format change.
- Mac worker replacement test: syntax error keeps the old worker; a valid blue replacement renders correctly and receives the original viewport/scale.
- Native Metal and forced CPU window probes each drew 180 changing frames without worker errors. Metal draw/submit P95: **1.95 ms**; CPU P95: **6.20 ms**, after warmup at a 1000×640 backing target. These are CPU-observed draw/submission durations, not GPU completion times.
- Windows managed application cross-build and portable audio/keyboard/visualization/tray/preferences tests passed. This does **not** compile or execute the Windows native C++ presentation backend on macOS.
- Existing macOS visualization host and staff beat regressions passed. These retain the old implementations as a comparison baseline.
- Manifest schema, shared physical-key identities and dependency-boundary checks passed. Fn is explicitly macOS-only where Windows does not report an equivalent physical event.

## Local performance sample

600 frames per output, first 60 excluded, after this task's concurrent pressure workload finished. Binary decode and atomic scene application are measured together; scripts and scene submission are separate.

| Output | Script P95 | Decode + apply P95 | Mean scene packet |
|---|---:|---:|---:|
| Pixel keyboard | 0.042 ms | 0.348 ms | 230 bytes |
| Staff note | 1.613 ms | 1.574 ms | 11,148 bytes |
| Pencil flight | 1.402 ms | 1.473 ms | 6,961 bytes |

These local samples meet the 2 ms thresholds. Earlier measurements while compilation and CPU pressure ran concurrently were higher. This is a development-machine sample, not a controlled two-platform performance certification or a comparison against the old renderer's total GPU cost.

A wall-clock 30-minute CPU raster stress run completed 70,177 frames, switching every 10 seconds and restarting the worker every five minutes. Combined Python host + worker RSS medians after each generation's first minute were approximately **125.3, 129.8, 132.8, 124.6, 118.6, 126.2 MiB**. This did not show sustained growth across generations. It ran alongside compilation and across implementation updates, so it is useful stress evidence, not the final frozen-build soak requirement. Its CPU pacing overruns are not a GPU dropped-frame measurement.

## Required before switching defaults

Windows native C++ compilation and physical-machine D3D12/DirectComposition validation remain unexecuted locally. The new CI workflow covers both platforms; its results must be checked independently of this local validation record. Transparency, mouse passthrough, WPF overlay ordering, monitor/DPI transitions and GPU-loss fallback need real Windows checks.

Both platforms still need reviewed matching screenshots, GPU completion measurements, end-to-end input/display latency, a fixed-machine before/after comparison, <1% sustained dropped-frame verification, and final-build 30-minute GPU runs. macOS hardware sleep/lock/display-scale transitions also remain manual acceptance items.

Consequently, step 4 (enable by default and remove old Swift/C# drawing/animation code) has intentionally **not** been performed. Implementation and validation commands are in `docs/plugin-migration.md`; machine-readable local measurements are in `plugin-runtime.json`.
