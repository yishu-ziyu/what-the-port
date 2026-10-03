#!/bin/bash
# Disposable binaries only. Never launch an app or call a capture/TCC API.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:?Usage: verify-screenshot-signing-stability.sh certificate-sha1 [evidence-directory]}"
EVIDENCE="${2:-$ROOT/.context/screenshot-permission/signing-stability}"
mkdir -p "$EVIDENCE"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/wtp-signing.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT

for VERSION in 1 2; do
    APP="$TEMP/version-$VERSION.app"
    mkdir -p "$APP/Contents/MacOS"
    printf 'int main(void) { return %s; }\n' "$VERSION" > "$TEMP/main.c"
    xcrun clang "$TEMP/main.c" -o "$APP/Contents/MacOS/SigningProbe"
    python3 - "$APP/Contents/Info.plist" "$VERSION" <<'PY'
import plistlib
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.whattheport.app.local.zh",
    "CFBundleExecutable": "SigningProbe",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": sys.argv[2],
}))
PY
    # Establish the failing baseline before applying the proposed certificate.
    codesign --force --sign - --timestamp=none "$APP"
    if bash "$ROOT/scripts/check-screenshot-signing.sh" "$APP" > "$EVIDENCE/adhoc-$VERSION.log" 2>&1; then
        echo 'FAIL: checker accepted an ad-hoc identity.' >&2
        exit 1
    fi
    grep -Fq 'FAIL: ad-hoc identity changes with the binary' "$EVIDENCE/adhoc-$VERSION.log"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP"
    codesign -dv --verbose=4 "$APP" > "$EVIDENCE/signed-$VERSION.log" 2>&1
    codesign -dr - "$APP" >> "$EVIDENCE/signed-$VERSION.log" 2>&1
done

HASH_ONE="$(shasum -a 256 "$TEMP/version-1.app/Contents/MacOS/SigningProbe" | awk '{print $1}')"
HASH_TWO="$(shasum -a 256 "$TEMP/version-2.app/Contents/MacOS/SigningProbe" | awk '{print $1}')"
[[ "$HASH_ONE" != "$HASH_TWO" ]] || { echo 'FAIL: probe binaries did not change.' >&2; exit 1; }
{
    printf 'Binary 1 SHA-256: %s\nBinary 2 SHA-256: %s\n' "$HASH_ONE" "$HASH_TWO"
    bash "$ROOT/scripts/check-screenshot-signing.sh" "$TEMP/version-2.app" "$TEMP/version-1.app"
} > "$EVIDENCE/result.log" 2>&1
cat "$EVIDENCE/result.log"
