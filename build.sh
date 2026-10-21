#!/bin/bash
# Builds a self-contained LocalFlow.app (engine libraries bundled inside) into ./build.
#   ./build.sh            build only
#   ./build.sh install    build + copy to /Applications + relaunch
#   ./build.sh zip        build + make ~/Desktop/LocalFlow.zip for sharing
#   ./build.sh notarize   build + notarize with Apple (keychain profile "LocalFlow") + staple + zip
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release 2>&1 | grep -v -E "^\[|warning:|ld: warning" | tail -5

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
for lib in "$FW"/*; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$lib" 2>&1 | grep -v "replacing existing" || true
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements Resources/LocalFlow.entitlements "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify --deep --strict "$APP" && echo "signed with: $IDENTITY"
du -sh "$APP" | awk '{print "built " $2 " (" $1 ")"}'

case "${1:-}" in
  install)
    pkill -x LocalFlow 2>/dev/null || true
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/LocalFlow.app
    open /Applications/LocalFlow.app
    echo "installed and launched /Applications/LocalFlow.app" ;;
  notarize)
    TMPZIP=$(mktemp -d)/LocalFlow-notarize.zip
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMPZIP"
    echo "submitting to Apple notarization service..."
    xcrun notarytool submit "$TMPZIP" --keychain-profile LocalFlow --wait 2>&1 | tee build/notarize.log | grep -E "id:|status:" | tail -3
    if grep -q "status: Accepted" build/notarize.log; then
      xcrun stapler staple "$APP" | tail -1
      spctl --assess --type execute -vv "$APP" 2>&1 | head -2
      STAGE=$(mktemp -d)/LocalFlow
      mkdir -p "$STAGE"
      cp -R "$APP" "$STAGE/"
      cp "Resources/Read me first.txt" "$STAGE/"
      rm -f ~/Desktop/LocalFlow.zip
      ditto -c -k --sequesterRsrc --keepParent "$STAGE" ~/Desktop/LocalFlow.zip
      ls -la ~/Desktop/LocalFlow.zip
    else
      echo "notarization was not accepted; see build/notarize.log"
      SUB=$(grep -m1 "id:" build/notarize.log | awk '{print $2}')
      [ -n "$SUB" ] && xcrun notarytool log "$SUB" --keychain-profile LocalFlow 2>&1 | head -40
      exit 1
    fi ;;
  zip)
    STAGE=$(mktemp -d)/LocalFlow
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    cp "Resources/Read me first.txt" "$STAGE/"
    rm -f ~/Desktop/LocalFlow.zip
    ditto -c -k --sequesterRsrc --keepParent "$STAGE" ~/Desktop/LocalFlow.zip
    ls -la ~/Desktop/LocalFlow.zip ;;
esac
