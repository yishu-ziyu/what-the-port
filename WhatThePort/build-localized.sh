#!/bin/bash
# Build a local bilingual edition with its own preferences and no upstream updater.
set -euo pipefail
cd "$(dirname "$0")"

export WTP_VERSION="${WTP_VERSION:-2.5.1}"
export WTP_BUILD="${WTP_BUILD:-15}"
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

codesign --force --sign - --timestamp=none "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"
echo "Built local bilingual edition: ${APP_DIR}"
