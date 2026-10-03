#!/bin/bash
# Read-only check. Never launch the app, capture the screen, or change TCC.
set -euo pipefail

APP="${1:?Usage: check-screenshot-signing.sh /path/to/WhatThePort.app [previous.app]}"
EXPECTED_ID="com.whattheport.app.local.zh"
codesign --verify --deep --strict "$APP"
INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
REQUIREMENT="$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')"

if ! grep -Fxq "Identifier=$EXPECTED_ID" <<< "$INFO"; then
    echo "FAIL: expected bilingual app identity $EXPECTED_ID" >&2
    exit 1
fi
if grep -Fxq 'Signature=adhoc' <<< "$INFO" || [[ "$REQUIREMENT" == cdhash* ]]; then
    echo 'FAIL: ad-hoc identity changes with the binary; Screen Recording grants cannot survive updates.' >&2
    exit 1
fi
if [[ -z "$REQUIREMENT" ]]; then
    echo 'FAIL: missing designated requirement.' >&2
    exit 1
fi

if [[ $# -gt 1 ]]; then
    PREVIOUS="$2"
    PREVIOUS_REQUIREMENT="$(codesign -dr - "$PREVIOUS" 2>&1 | sed -n 's/^designated => //p')"
    # TCC checks whether the current app satisfies the previously granted identity.
    codesign --verify --strict -R="$PREVIOUS_REQUIREMENT" "$APP"
    codesign --verify --strict -R="$REQUIREMENT" "$PREVIOUS"
    echo 'PASS: both builds satisfy each other’s designated requirement.'
fi
printf 'PASS: signed bilingual app has a version-independent identity.\n%s\n' "$REQUIREMENT"
echo 'NOT CHECKED: user permission, selection-to-clipboard, cancellation, or repeated screenshots.'
