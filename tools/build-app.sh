#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${C2_BUILD_DIR:-$ROOT/build}"
DEPS="${C2_DEPENDENCY_BIN:-$ROOT/build/dependencies/bin}"
APP="$BUILD/Carmageddon II for Apple Silicon.app"
EMCC_BIN="${EMCC:-emcc}"
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail 'Build this application on macOS with Xcode command-line tools.'
for helper in ffmpeg innoextract; do
    [ -x "$DEPS/$helper" ] || fail "Missing $helper. Build tools/dependencies first, or set C2_DEPENDENCY_BIN."
done
if [[ "$EMCC_BIN" != */* ]]; then EMCC_BIN="$(command -v "$EMCC_BIN")" || fail 'Set EMCC to Emscripten 3.1.50.'; fi
case "$("$EMCC_BIN" --version)" in *3.1.50*) ;; *) fail 'Emscripten 3.1.50 is required for the pinned runtime.' ;; esac
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"; APP="$BUILD/Carmageddon II for Apple Silicon.app"
STAGE="$(mktemp -d /private/tmp/c2-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/runtime" "$STAGE/runtime"
cat > "$STAGE/emcc" <<'SH'
#!/bin/sh
exec "$C2_REAL_EMCC" "$@"
SH
chmod +x "$STAGE/emcc"
printf '%s\n' 'Building the WebAssembly game runtime…'
C2_REAL_EMCC="$EMCC_BIN" EMCC="$STAGE/emcc" sh "$STAGE/runtime/build.sh"
SITE="$STAGE/runtime/dist/site"
NEXT="$STAGE/Carmageddon II for Apple Silicon.app"
mkdir -p "$NEXT/Contents/MacOS" "$NEXT/Contents/Helpers" "$NEXT/Contents/Resources/site" "$NEXT/Contents/Resources/Import" "$NEXT/Contents/Resources/Licenses"
printf '%s\n' 'Building the native launcher, data importer, and multiplayer relay…'
xcrun swiftc -module-cache-path "$BUILD/module-cache" -swift-version 5 -O -target arm64-apple-macos14.0 \
    -framework AppKit -framework WebKit -framework Network -framework AVKit -framework AVFoundation \
    "$ROOT"/host/*.swift -o "$NEXT/Contents/MacOS/CarmageddonII"
xcrun swiftc -module-cache-path "$BUILD/module-cache" -swift-version 5 -O -target arm64-apple-macos14.0 \
    "$ROOT/tools/DataImporter.swift" -o "$NEXT/Contents/Helpers/c2-data"
cp "$DEPS/ffmpeg" "$DEPS/innoextract" "$NEXT/Contents/Helpers/"
cp "$ROOT/packaging/Info.plist" "$NEXT/Contents/Info.plist"
cp "$ROOT/tools/data-loader.js.template" "$NEXT/Contents/Resources/Import/"
for name in index.html config.js carma2hy.js carma2hy.wasm; do cp "$SITE/$name" "$NEXT/Contents/Resources/site/"; done
cp "$ROOT/LICENSE" "$NEXT/Contents/Resources/Licenses/Runtime-GPL-3.0.txt"
cp "$ROOT/tools/dependencies/licenses/"* "$NEXT/Contents/Resources/Licenses/"
cp "$ROOT/tools/dependencies/sources.json" "$NEXT/Contents/Resources/Licenses/helper-sources.json"
xcrun swiftc -module-cache-path "$BUILD/module-cache" "$ROOT/tools/make-icon.swift" -o "$STAGE/make-icon"
"$STAGE/make-icon" "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$NEXT/Contents/Resources/AppIcon.icns"
printf '%s\n' 'Auditing the data-free application…'
python3 "$ROOT/tools/audit-release.py" "$NEXT"
xattr -cr "$NEXT"
for binary in "$NEXT/Contents/Helpers/"*; do codesign --force --sign "${C2_CODESIGN_IDENTITY:--}" "$binary"; done
codesign --force --sign "${C2_CODESIGN_IDENTITY:--}" "$NEXT"
codesign --verify --deep --strict "$NEXT"
if [ -e "$APP" ]; then
    /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -qx de.patrickbanfield.carmageddon2.local || fail 'Unexpected existing app at build destination.'
    rm -rf "$APP"
fi
ditto --noextattr --norsrc "$NEXT" "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
