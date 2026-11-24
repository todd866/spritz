#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_RUST=0
INSTALL=0
NOTARIZE=1

for arg in "$@"; do
  case "$arg" in
    --skip-rust) SKIP_RUST=1 ;;
    --install) INSTALL=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *)
      echo "Usage: $0 [--skip-rust] [--install] [--no-notarize]" >&2
      exit 2
      ;;
  esac
done

if [[ -n "${SPRITZ_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$SPRITZ_SIGN_IDENTITY"
else
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1 || true)"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "error: no Developer ID Application signing identity found (or set SPRITZ_SIGN_IDENTITY)" >&2
    exit 1
  fi
fi

PROFILE="${SPRITZ_NOTARY_PROFILE:-notarytool}"
if (( NOTARIZE )); then
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool keychain profile '$PROFILE' unavailable (set SPRITZ_NOTARY_PROFILE or pass --no-notarize)" >&2
    exit 1
  fi
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/macos/Resources/Info.plist")"
BUILD_ARGS=(--release)
if (( SKIP_RUST )); then
  BUILD_ARGS+=(--skip-rust)
fi

"$REPO_ROOT/scripts/build.sh" "${BUILD_ARGS[@]}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spritz-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

BUILT_APP="$REPO_ROOT/target/bundle-release/Spritz.app"
APP="$WORK/Spritz.app"
ditto "$BUILT_APP" "$APP"

codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime \
  --entitlements "$REPO_ROOT/macos/Resources/Spritz.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

DIST_DIR="$REPO_ROOT/target/release-dist"
mkdir -p "$DIST_DIR"
DMG_NAME="Spritz-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
rm -f "$DMG_PATH" "${DMG_PATH}.sha256"

STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Spritz.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Spritz" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if (( NOTARIZE )); then
  echo "Submitting $DMG_NAME for notarization (profile: $PROFILE)..."
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/notary.json"
  NOTARY_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$WORK/notary.json")"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    cat "$WORK/notary.json" >&2
    echo "error: notarization status '$NOTARY_STATUS'" >&2
    exit 1
  fi

  xcrun stapler staple "$DMG_PATH" >/dev/null
  xcrun stapler validate "$DMG_PATH" >/dev/null
  xcrun stapler staple "$APP" >/dev/null
  xcrun stapler validate "$APP" >/dev/null

  QUAR="$WORK/quarantine"
  mkdir -p "$QUAR"
  ditto "$APP" "$QUAR/Spritz.app"
  xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$QUAR/Spritz.app"
  spctl -a -t exec "$QUAR/Spritz.app"
fi

(cd "$DIST_DIR" && shasum -a 256 "$DMG_NAME" > "${DMG_NAME}.sha256")
echo "Built release artifact: $DMG_PATH"
cat "${DMG_PATH}.sha256"

if (( INSTALL )); then
  DEST="/Applications/Spritz.app"
  pkill -x Spritz || true
  for _ in $(seq 1 20); do
    pgrep -x Spritz >/dev/null || break
    sleep 0.1
  done
  rsync -a --delete "$APP/" "$DEST/"
  if (( NOTARIZE )); then
    spctl -a -t exec "$DEST"
  fi
  codesign --verify --deep --strict "$DEST"
  open -g "$DEST"
  sleep 1.5
  NEW_PID="$(pgrep -x Spritz || true)"
  if [[ -z "$NEW_PID" ]]; then
    echo "error: Spritz did not stay running after install" >&2
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
fi
