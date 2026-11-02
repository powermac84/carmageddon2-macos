#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${C2_BUILD_DIR:-$ROOT/build}"
APP="$BUILD/Carmageddon II for Apple Silicon.app"
DIST="${C2_DIST_DIR:-$ROOT/dist}"
TAG="$(tr -d '\r\n' < "$ROOT/VERSION")"
[ -d "$APP" ] || { printf '%s\n' 'Build the app first: bash tools/build-app.sh' >&2; exit 1; }
python3 "$ROOT/tools/audit-release.py" "$APP"
xattr -cr "$APP"; codesign --verify --deep --strict "$APP"
mkdir -p "$DIST"
STAGE="$(mktemp -d /private/tmp/c2-package.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/payload/Applications"
ditto --noextattr --norsrc "$APP" "$STAGE/payload/Applications/Carmageddon II for Apple Silicon.app"
cp "$ROOT/packaging/components.plist" "$STAGE/components.plist"
pkgbuild --root "$STAGE/payload" --component-plist "$STAGE/components.plist" \
    --identifier de.patrickbanfield.carmageddon2.installer --version 2.0.0 --install-location / "$STAGE/component.pkg"
cat > "$STAGE/distribution.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
<title>Carmageddon II for Apple Silicon</title>
<welcome file="welcome.html"/>
<options customize="never" require-scripts="false" hostArchitectures="arm64"/>
<allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
<choices-outline><line choice="default"><line choice="runtime"/></line></choices-outline>
<choice id="default"/>
<choice id="runtime" visible="false" title="Carmageddon II for Apple Silicon"><pkg-ref id="de.patrickbanfield.carmageddon2.installer"/></choice>
<pkg-ref id="de.patrickbanfield.carmageddon2.installer" version="2.0.0" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML
PKG="$DIST/Carmageddon-II-Apple-Silicon-$TAG.pkg"
productbuild --distribution "$STAGE/distribution.xml" --package-path "$STAGE" --resources "$ROOT/packaging" "$PKG"
pkgutil --expand-full "$PKG" "$STAGE/expanded"
python3 "$ROOT/tools/audit-release.py" "$STAGE/expanded"
APPZIP="$DIST/Carmageddon-II-Apple-Silicon-$TAG.zip"
ditto -c -k --keepParent --norsrc "$APP" "$APPZIP"
printf '%s\n' 'Installer payload and portable app ZIP are data-free.'
shasum -a 256 "$PKG" "$APPZIP" > "$DIST/SHA256SUMS.txt"
printf 'Release artifacts: %s\n' "$DIST"
