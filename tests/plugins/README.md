# Plugin regression tests

`replay.py` checks 奶牛猫 (`pixel-keyboard`) against 600 frozen head/tail samples captured from the earlier Swift simulator. The reference retains its original input SHA-256 and exact cat values; outputs belonging to removed plugins have been discarded. It covers silence, a display stall, keyboard recovery, session changes and audio format changes.

`niulai_replay.py`, `muffin_replay.py` and `heiji_kazuha_replay.py` verify the other three skins. Catalog and macOS host tests require all four named plugins, with 奶牛猫 first, and cover fallback from an unavailable saved selection.

The fixture stores a SHA-256 of the canonical input JSON. Changing the input generator must explicitly update and review the reference; the test never accepts current plugin output automatically. For intentional animation changes, inspect the affected frames and update only the expected values with a documented reason. Historical simulations can be recovered from Git history when needed; they are not compiled or shipped.

Run `sh scripts/build-plugins.sh`, then `sh scripts/test-plugins.sh`. macOS host selection, worker disposal and reload tests run with `zsh scripts/test-plugin-macos.sh`. Window and appearance tests use isolated preferences and are separate from real capture/device acceptance.

`plugin-exit-validation` (CTest) holds a reader until process teardown, after any static destructors registered by the first node validation. It then validates all supported node types and checks rejection of an unsupported type. This reproduces the async-close/static-type-table use-after-free without relying on repeated runs or sleeps. Keep node validation independent of destructible process-wide storage.
