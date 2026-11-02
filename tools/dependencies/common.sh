#!/bin/bash
set -euo pipefail
DEPS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEP_WORK="${C2_DEP_WORK:-$DEPS_SCRIPT_DIR/../../build/dependencies}"
mkdir -p "$DEP_WORK"
DEP_WORK="$(cd "$DEP_WORK" && pwd)"
DEP_JOBS="${JOBS:-8}"
case "$DEP_JOBS" in ''|*[!0-9]*) printf '%s\n' 'JOBS must be a positive integer.' >&2; exit 2 ;; esac
[ "$DEP_JOBS" -gt 0 ] && [ "$DEP_JOBS" -le 128 ] || exit 2
[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'These helper builds require macOS.' >&2; exit 2; }
mkdir -p "$DEP_WORK/downloads" "$DEP_WORK/sources" "$DEP_WORK/bin"
fetch_source() {
    local archive="$1" source_url="$2" expected="$3"
    if [ ! -f "$DEP_WORK/downloads/$archive" ]; then
        [ "${C2_OFFLINE:-0}" != 1 ] || { printf 'Missing offline source: %s\n' "$archive" >&2; exit 1; }
        curl --fail --location --retry 2 --connect-timeout 20 "$source_url" -o "$DEP_WORK/downloads/$archive"
    fi
    local actual
    actual="$(shasum -a 256 "$DEP_WORK/downloads/$archive" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || { printf 'Source checksum mismatch: %s\n' "$archive" >&2; exit 1; }
}
verify_helper() {
    local binary="$1" dependency
    [ "$(lipo -archs "$binary")" = arm64 ] || { printf 'Expected an arm64 helper: %s\n' "$binary" >&2; exit 1; }
    while IFS= read -r dependency; do
        case "$dependency" in /usr/lib/*|/System/Library/*) ;; *) printf 'Non-system runtime dependency: %s\n' "$dependency" >&2; exit 1 ;; esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
    if strings "$binary" | grep -E '/Users/|Dropbox'; then
        printf 'A personal build path is embedded in %s\n' "$binary" >&2; exit 1
    fi
    shasum -a 256 "$binary"
}
