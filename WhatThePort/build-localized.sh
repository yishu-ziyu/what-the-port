#!/bin/bash
# Build a local bilingual edition with its own preferences and no upstream updater.
set -euo pipefail
cd "$(dirname "$0")"

export WTP_VERSION="${WTP_VERSION:-2.5.1}"
export WTP_BUILD="${WTP_BUILD:-21}"
# A changing ad-hoc cdhash invalidates Screen Recording grants. Keep the local certificate identity.
if [[ -f local-signing.env ]]; then source local-signing.env; fi
: "${CODE_SIGN_IDENTITY:?Set CODE_SIGN_IDENTITY or local-signing.env to an existing signing certificate.}"
if [[ "${CODE_SIGN_IDENTITY}" == "-" ]]; then
    echo "Local bilingual builds require a stable certificate, not ad-hoc signing." >&2
    exit 1
fi
export CODE_SIGN_IDENTITY
./build-app.sh
APP_DIR=".build/WhatThePort.app"
test -d "${APP_DIR}/Contents/Resources/WhatThePort_WhatThePort.bundle"

python3 - "${APP_DIR}/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import sys

path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info['CFBundleIdentifier'] = 'com.whattheport.app.local.zh'
info['CFBundleDisplayName'] = 'WhatThePort 中文版'
info['CFBundleDevelopmentRegion'] = 'en'
info['CFBundleLocalizations'] = ['en', 'zh-Hans']
for key in ('SUFeedURL', 'SUPublicEDKey'):
    info.pop(key, None)
info['SUEnableAutomaticChecks'] = False
info['SUAutomaticallyUpdate'] = False
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PY

mkdir -p "${APP_DIR}/Contents/Resources/Licenses"
cp ../LICENSE ../NOTICE.md "${APP_DIR}/Contents/Resources/Licenses/"
cp ../LICENSES/* "${APP_DIR}/Contents/Resources/Licenses/"

# Local usage-enabled builds bundle the reader, never reference the old GUI installation at runtime.
HELPER_DIR="${WTP_CODEXBAR_HELPER_DIR:-.build/ai-usage-reader}"
if [[ -x "${HELPER_DIR}/CodexBarCLI" ]]; then
    test -d "${HELPER_DIR}/CodexBar_CodexBarCore.bundle"
    mkdir -p "${APP_DIR}/Contents/Helpers"
    ditto "${HELPER_DIR}/CodexBarCLI" "${APP_DIR}/Contents/Helpers/CodexBarCLI"
    ditto "${HELPER_DIR}/CodexBar_CodexBarCore.bundle" "${APP_DIR}/Contents/Helpers/CodexBar_CodexBarCore.bundle"
fi

codesign --force --sign "${CODE_SIGN_IDENTITY}" --options runtime --timestamp "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"
echo "Built local bilingual edition: ${APP_DIR}"
