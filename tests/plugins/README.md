# Plugin regression tests

`replay.py` compares three bundled Lua visualizations over 600 deterministic frames each. `reference.json.gz` stores the numerical output of the pre-removal Swift simulations, captured on 2026-10-30 and checked against the Lua implementations before removal. It includes melody dropouts, silence, a display stall, keyboard recovery, session changes and audio format changes. `trace_reference.py` independently reconstructs trace geometry from those samples.

The fixture stores a SHA-256 of the canonical input JSON. Changing the input generator must explicitly update and review the reference; the test never accepts current plugin output automatically. For intentional animation changes, inspect the affected frames and update only the expected values with a documented reason. Historical simulations can be recovered from Git history when needed; they are not compiled or shipped.

Run `sh scripts/build-plugins.sh`, then `sh scripts/test-plugins.sh`. macOS host selection, worker disposal and reload tests run with `zsh scripts/test-plugin-macos.sh`. Window and appearance tests use isolated preferences and are separate from real capture/device acceptance.

`plugin-exit-validation` (CTest) holds a reader until process teardown, after any static destructors registered by the first node validation. It then validates all supported node types and checks rejection of an unsupported type. This reproduces the async-close/static-type-table use-after-free without relying on repeated runs or sleeps. Keep node validation independent of destructible process-wide storage.
