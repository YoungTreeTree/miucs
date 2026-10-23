#!/bin/zsh
# Sourced by build/test entrypoints after setting root to the repository directory.
# Named groups make platform dependencies explicit; Windows placeholders are never compiled.
audio_core=("$root"/modules/audio/core/*.swift)
audio_macos=("$root"/modules/audio/platforms/macos/*.swift)
fft_macos=("$root/modules/audio/platforms/macos/AccelerateSpectrumTransform.swift")
pcm_macos=("$root/modules/audio/platforms/macos/AudioPCMDecoder.swift")
visualization_core=("$root"/modules/visualizations/api/*.swift "$root"/modules/visualizations/pencil-flight/core/*.swift)
visualization_macos=("$root"/modules/visualizations/api/platforms/macos/*.swift "$root"/modules/visualizations/pencil-flight/platforms/macos/*.swift)
app_macos=("$root"/apps/macos/*.swift)
host_macos=(${app_macos:#*/App.swift})
tool_libraries=("$root/tools/macos/AudioDiagnostics.swift" "$root/tools/macos/FlightPreview.swift")
native_libraries=("${audio_core[@]}" "${audio_macos[@]}" "${visualization_core[@]}" "${visualization_macos[@]}" "${host_macos[@]}" "${tool_libraries[@]}")
app_sources=("${native_libraries[@]}" "$root/apps/macos/App.swift")
