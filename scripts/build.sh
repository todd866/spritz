#!/bin/bash
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="debug"
SKIP_RUST=0
for arg in "$@"; do
  case "$arg" in
    --release) PROFILE="release" ;;
    --debug) PROFILE="debug" ;;
    --skip-rust) SKIP_RUST=1 ;;
    *)
      echo "Usage: $0 [--debug|--release] [--skip-rust]" >&2
      exit 2
      ;;
  esac
done

if [[ "$PROFILE" == "release" ]]; then
  if [[ "$SKIP_RUST" != "1" ]]; then
    cargo build -p spritz-macos --release -j 4
  fi
  RUST_LIB_DIR="$REPO_ROOT/target/release"
  SPRITZ_RUST_PROFILE="release" SPRITZ_RUST_LIB_DIR="$RUST_LIB_DIR" \
    swift build --package-path macos -c release -j 2 -Xlinker -dead_strip
  BIN_PATH="$REPO_ROOT/macos/.build/release/Spritz"
else
  if [[ "$SKIP_RUST" != "1" ]]; then
    cargo build -p spritz-macos -j 4
  fi
  RUST_LIB_DIR="$REPO_ROOT/target/debug"
  SPRITZ_RUST_PROFILE="debug" SPRITZ_RUST_LIB_DIR="$RUST_LIB_DIR" \
    swift build --package-path macos -c debug -j 2
  BIN_PATH="$REPO_ROOT/macos/.build/debug/Spritz"
fi

BUNDLE_DIR="$REPO_ROOT/target/bundle-$PROFILE/Spritz.app"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"

cp "$BIN_PATH" "$BUNDLE_DIR/Contents/MacOS/Spritz"
if [[ "$PROFILE" == "release" ]]; then
  strip -x "$BUNDLE_DIR/Contents/MacOS/Spritz"
fi
cp "$REPO_ROOT/macos/Resources/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"
cp "$REPO_ROOT/macos/Resources/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
cp "$REPO_ROOT/macos/Resources/MenuBarIcon.pdf" "$BUNDLE_DIR/Contents/Resources/MenuBarIcon.pdf"
printf 'APPL????' > "$BUNDLE_DIR/Contents/PkgInfo"

echo "Built $BUNDLE_DIR"
