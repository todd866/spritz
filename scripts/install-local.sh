#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SIGN_IDENTITY="${SPRITZ_SIGN_IDENTITY:-Developer ID Application: Ian Todd (U87MQBZKJ5)}"
DEST="/Applications/Spritz.app"
ROLLBACK_DIR="$HOME/.local/state/spritz/rollback-swift-20261124"

SKIP_BUILD="${SPRITZ_SKIP_BUILD:-0}"
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=1
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  if [[ "${SPRITZ_NO_HEAVY_SLOT:-0}" != "1" ]] && command -v heavy-slot >/dev/null; then
    HEAVY_SLOT_LOCAL=1 heavy-slot -- "$REPO_ROOT/scripts/build.sh" --release
  else
    "$REPO_ROOT/scripts/build.sh" --release
  fi
fi

APP_PATH="$REPO_ROOT/target/bundle-release/Spritz.app"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
  --entitlements "$REPO_ROOT/macos/Resources/Spritz.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

if [[ -d "$DEST" && ! -d "$ROLLBACK_DIR/Spritz.app" ]]; then
  mkdir -p "$ROLLBACK_DIR"
  ditto "$DEST" "$ROLLBACK_DIR/Spritz.app"
  echo "Backed up existing Spritz.app to $ROLLBACK_DIR/Spritz.app"
fi

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
