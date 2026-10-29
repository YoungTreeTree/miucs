# One UI per plugin — 2026-10-29

The built-in package is split into `pixel-keyboard`, `pencil-flight` and `staff-note`. Each manifest has one top-level ID/name/layout and each folder includes its required scripts, fonts and images. Existing visualization IDs and window preference keys remain unchanged. Legacy multi-output manifests and plugin tray declarations are rejected with a migration message.

The application owns the cat logo and tray animation. The visualization menu selects directly from the plugin catalog. Plugin scans do not launch workers; switching disposes the previous package; hiding the floating view stops plugin scheduling. Explicit reload can still validate a hidden selected instance. The tray has no Lua package or surface dependency.

Local checks on macOS:

- 37 native core checks, including three isolated built-in scenes, no tray outputs and rejection of the old manifest format.
- 68 process/transport checks and template lifecycle/resource validation.
- 600-frame Swift/Lua replay for each plugin, preserving keyboard head/tail, flight and staff/ring/path behavior.
- CPU previews for all three folders, plus native Metal staff and forced-CPU keyboard surface probes with no worker errors.
- macOS host regression: scans create no workers; selecting a UI creates only its package; disposal releases it and preserves the application tray. Failed/successful reload behavior also passes.
- Windows managed application cross-build and portable core tests pass. This is not a Windows native presentation run for this revision.

Tests ran alongside compilation. Timing values from this run are not controlled performance acceptance measurements. The earlier implementation record remains in `plugin-runtime.md`; its single-package layout describes the pre-split version. Native Windows validation for this revision and the broader release gates remain separate from these local checks.
