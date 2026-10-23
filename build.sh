#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app="$root/dist/Miucs.app"
source "$root/scripts/swift-sources.sh"
rapidly_flags=()
with_rapidly=false
if [[ "${1:-}" == "--rapidly" ]]; then
  with_rapidly=true
  zsh "$root/scripts/setup-rapidly.sh"
  zsh "$root/scripts/setup-singing-pitch.sh"
  rapidly_framework="$root/build/rapidly/RapidlyEngine.xcframework/macos-arm64_x86_64"
  rapidly_flags=(-F "$rapidly_framework" -framework RapidlyEngineC
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
elif [[ $# -gt 0 ]]; then
  print -u2 "Usage: zsh build.sh [--rapidly]"
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
  -framework CoreML \
  "${rapidly_flags[@]}" \
  -o "$app/Contents/MacOS/Miucs" \
  "${app_sources[@]}"

cp "$root/apps/macos/Info.plist" "$app/Contents/Info.plist"
if $with_rapidly; then
  mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources/Rapidly"
  ditto "$rapidly_framework/RapidlyEngineC.framework" "$app/Contents/Frameworks/RapidlyEngineC.framework"
  cp "$root/build/rapidly/"{music-stem-separation-96ms.v1.1.rapidly,LICENSE,NOTICE.txt} "$app/Contents/Resources/Rapidly/"
  mkdir -p "$app/Contents/Resources/SingingPitch"
  ditto "$root/build/singing-pitch/SingingPitch.mlmodelc" "$app/Contents/Resources/SingingPitch/SingingPitch.mlmodelc"
  cp "$root/build/singing-pitch/"{LICENSE-torchcrepe.txt,conversion.json} "$app/Contents/Resources/SingingPitch/"
  cp "$root/docs/licenses/crepe.txt" "$app/Contents/Resources/SingingPitch/LICENSE-crepe.txt"
fi

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

if $with_rapidly; then
  codesign --force --sign "Miucs Dev" "$app/Contents/Frameworks/RapidlyEngineC.framework"
fi
codesign --force --sign "Miucs Dev" "$app"
echo "built $app"
