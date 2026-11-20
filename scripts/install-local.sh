#!/bin/bash
# Build a Developer ID signed Release Spritz.app and install/relaunch it in /Applications,
# preserving Accessibility and Input Monitoring TCC grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/check_telemetry.py
python3 scripts/check_localizations.py

mkdir -p Mojito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp scripts/fork-packages.resolved Mojito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
export KLIPY_API_KEY="${KLIPY_API_KEY:-}"
python3 scripts/build_klipy_key.py

SIGN_IDENTITY="${SPRITZ_SIGN_IDENTITY:-Developer ID Application: Ian Todd (U87MQBZKJ5)}"
TEAM_ID="${SPRITZ_TEAM_ID:-U87MQBZKJ5}"
DERIVED="${MOJITO_RELEASE_DERIVED_DATA:-$HOME/Library/Caches/MojitoFork/DerivedRelease}"

BUILD_CMD=(xcodebuild build
  -project Mojito.xcodeproj
  -scheme Mojito
  -configuration Release
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  -disableAutomaticPackageResolution
  DEVELOPMENT_TEAM="$TEAM_ID"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"
  MOJITO_INSTALL_DEV_APP=NO
)

if [[ "${SPRITZ_NO_HEAVY_SLOT:-0}" != "1" ]] && command -v heavy-slot >/dev/null; then
  HEAVY_SLOT_LOCAL=1 heavy-slot -- "${BUILD_CMD[@]}"
else
  "${BUILD_CMD[@]}"
fi

APP_PATH="$DERIVED/Build/Products/Release/Spritz.app"
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FW/Versions/B"
for target in \
  "$SPARKLE_VERSION/XPCServices/Downloader.xpc" \
  "$SPARKLE_VERSION/XPCServices/Installer.xpc" \
  "$SPARKLE_VERSION/Updater.app" \
  "$SPARKLE_VERSION/Autoupdate" \
  "$SPARKLE_FW"; do
  if [[ -e "$target" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$target"
  fi
done

codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
  --entitlements Resources/Mojito.entitlements "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

DEST="/Applications/Spritz.app"
pkill -x Spritz || true
for _ in $(seq 1 20); do
  pgrep -x Spritz >/dev/null || break
  sleep 0.1
done

rsync -a --delete "$APP_PATH/" "$DEST/"
codesign --verify --deep --strict "$DEST"
open -g "$DEST"
sleep 1.5

NEW_PID=$(pgrep -x Spritz || true)
if [[ -z "$NEW_PID" ]]; then
  echo "error: Spritz did not stay running after launch" >&2
  exit 1
fi

echo "Installed and launched $DEST (PID $NEW_PID)"
swift -e '
import CoreGraphics
var count: UInt32 = 0
CGGetEventTapList(0, nil, &count)
var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
CGGetEventTapList(count, &list, &count)
let matched = list.filter { $0.tappingProcess == '"$NEW_PID"' }
for tap in matched {
    print("CGEventTap pid=\(tap.tappingProcess) enabled=\(tap.enabled) events=0x\(String(tap.eventsOfInterest, radix: 16))")
}
if matched.isEmpty || matched.contains(where: { !$0.enabled }) { exit(1) }
'
