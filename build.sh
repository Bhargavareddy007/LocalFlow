#!/bin/bash
# Builds a self-contained LocalFlow.app (engine libraries bundled inside) into ./build.
#   ./build.sh            build only
#   ./build.sh install    build + copy to /Applications + relaunch
#   ./build.sh zip        build + make ~/Desktop/LocalFlow.zip for sharing
#   ./build.sh dmg        build + make ~/Desktop/LocalFlow-unnotarized.dmg to check the disk image
#   ./build.sh notarize   build + notarize with Apple (keychain profile "LocalFlow") + staple + zip and dmg
# The zip holds the app alone (it downloads the speech model on first launch); the dmg's app carries the
# default speech model inside, so a new install has nothing to download.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -v -E "^\[" | tail -5

APP=build/LocalFlow.app
FW="$APP/Contents/Frameworks"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FW"
cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift "$PWD/Resources/AppIcon.icns" || true
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# --- bundle the whisper.cpp / ggml libraries so the app runs without Homebrew ---
WC=/opt/homebrew/opt/whisper.cpp/lib
GG=/opt/homebrew/opt/ggml
OMP=/opt/homebrew/opt/libomp/lib
LL=/opt/homebrew/opt/llama.cpp/lib
cp "$WC/libwhisper.1.dylib" "$WC/libparakeet.1.dylib" "$GG/lib/libggml.0.dylib" "$GG/lib/libggml-base.0.dylib" "$OMP/libomp.dylib" "$LL/libllama.0.dylib" "$FW/"
cp "$GG"/libexec/libggml-*.so "$FW/"
chmod u+w "$FW"/*

BIN="$APP/Contents/MacOS/LocalFlow"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN"
install_name_tool \
  -change "$WC/libwhisper.1.dylib"      @rpath/libwhisper.1.dylib \
  -change "$WC/libparakeet.1.dylib"     @rpath/libparakeet.1.dylib \
  -change "$GG/lib/libggml.0.dylib"     @rpath/libggml.0.dylib \
  -change "$GG/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib \
  -change "$LL/libllama.0.dylib"         @rpath/libllama.0.dylib \
  "$BIN"
for lib in "$FW"/*; do
  name=$(basename "$lib")
  install_name_tool -id "@rpath/$name" "$lib" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
  install_name_tool \
    -change "$WC/libwhisper.1.dylib"      @rpath/libwhisper.1.dylib \
    -change "$WC/libparakeet.1.dylib"     @rpath/libparakeet.1.dylib \
    -change "$GG/lib/libggml.0.dylib"     @rpath/libggml.0.dylib \
    -change "$GG/lib/libggml-base.0.dylib" @rpath/libggml-base.0.dylib \
    -change "$OMP/libomp.dylib"           @rpath/libomp.dylib \
    -change "$LL/libllama.0.dylib"         @rpath/libllama.0.dylib \
    "$lib"
done
if otool -L "$BIN" "$FW"/* | grep -q "/opt/homebrew"; then
  echo "ERROR: a Homebrew path is still referenced:"; otool -L "$BIN" "$FW"/* | grep "/opt/homebrew"; exit 1
fi

# --- sign everything with the same identity (hardened runtime, ready for notarization) ---
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
[ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)
[ -z "$IDENTITY" ] && IDENTITY="-"
case "${1:-}" in
  notarize|zip|dmg)
    # A build meant for other Macs must carry the Developer ID signature, never an ad-hoc one.
    [[ "$IDENTITY" == "Developer ID Application"* ]] || { echo "ERROR: no Developer ID Application identity in the keychain"; exit 1; } ;;
esac
sign() {
  local out
  if ! out=$(codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" 2>&1); then
    echo "$out"; echo "ERROR: signing failed: ${*: -1}"; exit 1
  fi
}
# Submits a file to Apple's notarization service and staples the ticket to it; exits on rejection.
notarize() {
  local log="build/notarize-$(basename "$1").log"
  # A large upload can time out; a submission that got no verdict is sent again, up to three times.
  for attempt in 1 2 3; do
    echo "submitting $(basename "$1") to Apple notarization service (attempt $attempt)..."
    # `|| true`: a failed submission must reach the error report below instead of exiting silently.
    xcrun notarytool submit "$2" --keychain-profile LocalFlow --wait 2>&1 | tee "$log" | grep -E "id:|status:" | tail -3 || true
    grep -q "status:" "$log" && break
  done
  if ! grep -q "status: Accepted" "$log"; then
    echo "notarization was not accepted; see $log"
    grep -E "^Error" "$log" || true
    SUB=$(grep -m1 "id:" "$log" | awk '{print $2}' || true)
    [ -n "$SUB" ] && xcrun notarytool log "$SUB" --keychain-profile LocalFlow 2>&1 | head -40
    exit 1
  fi
  xcrun stapler staple "$1" | tail -1
}
# Disk image: the app next to an Applications shortcut, with an arrow between them. dmgbuild (a Python
# tool that writes the Finder window layout) is installed once into build/dmgvenv.
make_dmg() {
  [ -x build/dmgvenv/bin/dmgbuild ] || { python3 -m venv build/dmgvenv && build/dmgvenv/bin/pip install -q 'dmgbuild==1.6.7'; }
  local bg; bg=$(mktemp -d)
  swift scripts/make-dmg-background.swift "$bg"
  rm -f "$2"
  build/dmgvenv/bin/dmgbuild -s scripts/dmg-settings.py -D app="$1" -D background="$bg/bg.png" \
    -D icon=Resources/AppIcon.icns LocalFlow "$2" > /dev/null
  codesign --force --sign "$IDENTITY" --timestamp "$2"
  ls -la "$2"
}
# The disk image's app: the same app plus the default speech model in Contents/Resources/models, re-signed.
# The model is the file pinned in ModelManager.swift, fetched once into build/models and checked against
# its pinned SHA-256 every time. Made before the plain app is stapled, so it carries no stale ticket.
BIG=build/dmg/LocalFlow.app
bundled_app() {
  local url sha file
  url=$(grep -o 'https://huggingface.co/ggml-org/parakeet-GGUF/resolve/[^"]*' Sources/LocalFlow/ModelManager.swift)
  sha=$(sed -n '/static let parakeet/,/sha256:/p' Sources/LocalFlow/ModelManager.swift | grep -o '[0-9a-f]\{64\}')
  file=$(basename "$url")
  mkdir -p build/models
  if ! echo "$sha  build/models/$file" | shasum -a 256 -c -s 2>/dev/null; then
    echo "downloading $file..."
    curl -fL --proto '=https' --proto-redir '=https' -o "build/models/$file.part" "$url"
    mv "build/models/$file.part" "build/models/$file"
  fi
  echo "$sha  build/models/$file" | shasum -a 256 -c -s || { echo "ERROR: $file does not match its pinned SHA-256"; exit 1; }
  rm -rf build/dmg
  mkdir -p build/dmg
  cp -R "$APP" build/dmg/
  mkdir -p "$BIG/Contents/Resources/models"
  cp -c "build/models/$file" "$BIG/Contents/Resources/models/"
  cp Resources/MODEL-NOTICE.txt "$BIG/Contents/Resources/models/NOTICE.txt"   # the model's CC BY 4.0 credit
  sign --entitlements Resources/LocalFlow.entitlements "$BIG"
  codesign --verify --deep --strict "$BIG"
  du -sh "$BIG" | awk '{print "built " $2 " with the speech model (" $1 ")"}'
}
for lib in "$FW"/*; do sign "$lib"; done
sign --entitlements Resources/LocalFlow.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "signed with: $IDENTITY"
du -sh "$APP" | awk '{print "built " $2 " (" $1 ")"}'

case "${1:-}" in
  install)
    pkill -x LocalFlow 2>/dev/null || true
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/LocalFlow.app
    open /Applications/LocalFlow.app
    echo "installed and launched /Applications/LocalFlow.app" ;;
  notarize)
    bundled_app
    TMPZIP=$(mktemp -d)/LocalFlow-notarize.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMPZIP"
    notarize "$APP" "$TMPZIP"
    spctl --assess --type execute -vv "$APP" 2>&1 | head -2
    STAGE=$(mktemp -d)/LocalFlow
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    cp "Resources/Read me first.txt" "$STAGE/"
    rm -f ~/Desktop/LocalFlow.zip
    ditto -c -k --sequesterRsrc --keepParent "$STAGE" ~/Desktop/LocalFlow.zip
    ls -la ~/Desktop/LocalFlow.zip
    BIGZIP=$(mktemp -d)/LocalFlow-bundled-notarize.zip
    ditto -c -k --keepParent "$BIG" "$BIGZIP"
    notarize "$BIG" "$BIGZIP"
    make_dmg "$BIG" ~/Desktop/LocalFlow.dmg
    notarize ~/Desktop/LocalFlow.dmg ~/Desktop/LocalFlow.dmg
    spctl --assess --type open --context context:primary-signature -vv ~/Desktop/LocalFlow.dmg 2>&1 | head -2 ;;
  dmg)
    # Not notarized, so it gets its own name and never replaces the notarized ~/Desktop/LocalFlow.dmg.
    bundled_app
    make_dmg "$BIG" ~/Desktop/LocalFlow-unnotarized.dmg ;;
  zip)
    # Not notarized, so it gets its own name and never replaces the notarized ~/Desktop/LocalFlow.zip.
    STAGE=$(mktemp -d)/LocalFlow
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    cp "Resources/Read me first.txt" "$STAGE/"
    rm -f ~/Desktop/LocalFlow-unnotarized.zip
    ditto -c -k --sequesterRsrc --keepParent "$STAGE" ~/Desktop/LocalFlow-unnotarized.zip
    ls -la ~/Desktop/LocalFlow-unnotarized.zip ;;
esac
