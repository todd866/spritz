#!/bin/bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_CORE=0
UPDATE_DOCS=0
for arg in "$@"; do
  case "$arg" in
    --skip-core) SKIP_CORE=1 ;;
    --update-docs-screenshots) UPDATE_DOCS=1 ;;
    *)
      echo "Usage: $0 [--skip-core] [--update-docs-screenshots]" >&2
      exit 2
      ;;
  esac
done

echo "==> 1. Rust workspace tests"
cargo test --workspace -j 2

if (( ! SKIP_CORE )); then
  echo "==> 2. Rebuilding SpritzCore.xcframework"
  "$REPO_ROOT/scripts/build-ios-core.sh"
else
  echo "==> 2. Skipping SpritzCore.xcframework rebuild (--skip-core)"
fi

echo "==> 3. Resolving headless iOS Simulator"
SIM_INFO="$(python3 - <<'PY'
import json, subprocess

raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if not d.get("isAvailable", True):
            continue
        name = d.get("name", "")
        if "iPhone" in name:
            priority = (
                0 if d.get("state") == "Booted" else 1,
                0 if "Duo" in name else 1,
                name,
            )
            candidates.append((priority, d["udid"], d.get("state", "Shutdown"), name))
if not candidates:
    raise SystemExit("No available iPhone simulator found")
candidates.sort(key=lambda item: item[0])
_, udid, state, name = candidates[0]
print(f"{udid}\t{state}\t{name}")
PY
)"

IFS=$'\t' read -r SIM_UDID SIM_INITIAL_STATE SIM_NAME <<< "$SIM_INFO"
echo "Selected simulator: $SIM_NAME ($SIM_UDID, state=$SIM_INITIAL_STATE)"

DID_BOOT=0
cleanup() {
  xcrun simctl terminate "$SIM_UDID" io.github.todd866.SpritzMobile >/dev/null 2>&1 || true
  if (( DID_BOOT )); then
    xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ "$SIM_INITIAL_STATE" != "Booted" ]]; then
  xcrun simctl boot "$SIM_UDID"
  DID_BOOT=1
fi
xcrun simctl bootstatus "$SIM_UDID" -b

XCCONFIG_ARGS=()
PRIVATE_XCCONFIG="$HOME/.config/spritz/ios-private.xcconfig"
if [[ -f "$PRIVATE_XCCONFIG" ]]; then
  XCCONFIG_ARGS=(-xcconfig "$PRIVATE_XCCONFIG")
fi

echo "==> 4. Running SpritzMobileTests + SpritzMobileUITests"
xcodebuild test \
  -project "$REPO_ROOT/ios/SpritzMobile.xcodeproj" \
  -scheme SpritzMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$REPO_ROOT/target/ios-sim" \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  "${XCCONFIG_ARGS[@]}"

echo "==> 5. Capturing headless Light & Dark visual QA renders"
QA_DIR="/tmp/spritz-ios-qa"
mkdir -p "$QA_DIR"
APP_PATH="$REPO_ROOT/target/ios-sim/Build/Products/Debug-iphonesimulator/SpritzMobile.app"
BUNDLE_ID="io.github.todd866.SpritzMobile"
xcrun simctl install "$SIM_UDID" "$APP_PATH"

capture() {
  local appearance="$1"
  local label="$2"
  shift 2
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl ui "$SIM_UDID" appearance "$appearance"
  xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" "$@" >/dev/null
  sleep 1.6
  local out_file="$QA_DIR/${appearance}-${label}.png"
  xcrun simctl io "$SIM_UDID" screenshot --display=1 "$out_file" >/dev/null
  if [[ ! -s "$out_file" ]]; then
    echo "Empty screenshot: $out_file" >&2
    exit 1
  fi
}

capture dark keyboard --preview-tab keyboard --preview-deck abc
capture dark tools --preview-tab keyboard --preview-deck tools
capture dark emoji --preview-tab keyboard --preview-deck emoji
capture dark typing --preview-tab typing
capture light keyboard --preview-tab keyboard --preview-deck abc
capture light emoji --preview-tab emoji
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

if (( UPDATE_DOCS )); then
  cp "$QA_DIR/dark-keyboard.png" "$REPO_ROOT/docs/screenshots/ios-keyboard-dark.png"
  cp "$QA_DIR/light-keyboard.png" "$REPO_ROOT/docs/screenshots/ios-keyboard-light.png"
  cp "$QA_DIR/dark-tools.png" "$REPO_ROOT/docs/screenshots/ios-tools-dark.png"
  cp "$QA_DIR/dark-emoji.png" "$REPO_ROOT/docs/screenshots/ios-emoji-dark.png"
  echo "Updated docs/screenshots/ios-*.png"
fi

echo "==> 6. Privacy & config hygiene check"
if git ls-files -z -- 'ios/' | xargs -0 rg -n "DEVELOPMENT_TEAM = [A-Z0-9]{10}" >/dev/null; then
  echo "Tracked ios/ file contains a populated DEVELOPMENT_TEAM!" >&2
  exit 1
fi
if git ls-files -z ':!crates/spritz-core/data/*' | xargs -0 rg -n "/Users/[a-zA-Z0-9._-]+" >/dev/null; then
  echo "Tracked file contains a hardcoded /Users/<user> path!" >&2
  git ls-files -z ':!crates/spritz-core/data/*' | xargs -0 rg -n "/Users/[a-zA-Z0-9._-]+" >&2
  exit 1
fi
AUDIT_PATTERNS="$HOME/.config/spritz/audit-patterns.txt"
if [[ -f "$AUDIT_PATTERNS" ]] && git ls-files -z ':!crates/spritz-core/data/*' | xargs -0 rg -n -i -f "$AUDIT_PATTERNS" >/dev/null; then
  echo "Private audit pattern matched in tracked files!" >&2
  exit 1
fi

echo "ALL iOS CHECKS PASSED (renders in $QA_DIR)"
