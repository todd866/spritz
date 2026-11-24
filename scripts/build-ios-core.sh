#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SIM_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --sim-only) SIM_ONLY=1 ;;
    *)
      echo "Usage: $0 [--sim-only]" >&2
      exit 2
      ;;
  esac
done

cargo build -p spritz-ios --release --target aarch64-apple-ios-sim -j 2
if (( ! SIM_ONLY )); then
  cargo build -p spritz-ios --release --target aarch64-apple-ios -j 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spritz-xcfw.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

HEADERS_DIR="$REPO_ROOT/ios/SpritzCoreFFI/include"
OUT_XCFW="$REPO_ROOT/ios/Frameworks/SpritzCore.xcframework"
mkdir -p "$REPO_ROOT/ios/Frameworks"

if (( SIM_ONLY )); then
  xcodebuild -create-xcframework \
    -library "$REPO_ROOT/target/aarch64-apple-ios-sim/release/libspritz_ios.a" \
    -headers "$HEADERS_DIR" \
    -output "$WORK/SpritzCore.xcframework"
else
  xcodebuild -create-xcframework \
    -library "$REPO_ROOT/target/aarch64-apple-ios/release/libspritz_ios.a" \
    -headers "$HEADERS_DIR" \
    -library "$REPO_ROOT/target/aarch64-apple-ios-sim/release/libspritz_ios.a" \
    -headers "$HEADERS_DIR" \
    -output "$WORK/SpritzCore.xcframework"
fi

if [[ -e "$OUT_XCFW" ]]; then
  mv "$OUT_XCFW" "$WORK/old-xcframework"
fi
mv "$WORK/SpritzCore.xcframework" "$OUT_XCFW"
echo "Built $OUT_XCFW"
