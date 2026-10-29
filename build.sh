#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$root/dist/Miucs.app"
source "$root/scripts/swift-sources.sh"
if [[ $# -gt 0 ]]; then
  print -u2 "Usage: zsh build.sh"
  exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"

swiftc \
  -parse-as-library \
  -swift-version 6 \
  -O \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework CoreAudio \
  -framework Accelerate \
  -o "$app/Contents/MacOS/Miucs" \
  "${app_sources[@]}"

cp "$root/apps/macos/Info.plist" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp "$root/modules/visualizations/pixel-keyboard/assets/cat-head.png" "$app/Contents/Resources/PixelCatHead.png"

# Ad-hoc signatures change on every build, so macOS drops the screen-recording grant.
# A stable self-signed identity keeps the TCC permission across rebuilds.
if ! security find-identity -p codesigning | grep -q "Miucs Dev"; then
  support="$HOME/Library/Application Support/Miucs"
  mkdir -p "$support"
  cat > "$support/cert.cfg" <<'EOF'
[req]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no
[req_dn]
CN = Miucs Dev
[codesign_ext]
basicConstraints = CA:false
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$support/key.pem" -out "$support/cert.pem" \
    -days 3650 -nodes -config "$support/cert.cfg" >/dev/null 2>&1
  openssl pkcs12 -export -legacy \
    -inkey "$support/key.pem" -in "$support/cert.pem" \
    -out "$support/miucs-dev.p12" -passout pass:miucs >/dev/null 2>&1
  security import "$support/miucs-dev.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P miucs -A -T /usr/bin/codesign >/dev/null
fi

if [[ "${MIUCS_BUILD_PLUGINS:-0}" == "1" ]]; then
  sh "$root/scripts/build-plugins.sh"
  cp "$root/build/plugins/libmiucs_plugins.dylib" "$app/Contents/MacOS/"
  cp "$root/build/plugins/miucs-plugin-worker" "$app/Contents/MacOS/"
  cp -R "$root/plugins" "$app/Contents/Resources/Plugins"
  cp -R "$root/third_party/plugin-licenses" "$app/Contents/Resources/PluginLicenses"
  codesign --force --sign "Miucs Dev" "$app/Contents/MacOS/libmiucs_plugins.dylib"
  codesign --force --sign "Miucs Dev" "$app/Contents/MacOS/miucs-plugin-worker"
fi
codesign --force --sign "Miucs Dev" "$app"
echo "built $app"
