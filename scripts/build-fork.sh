#!/bin/bash
# Build from the committed project with pinned packages; never install or launch.
set -euo pipefail
cd "$(dirname "$0")/.."
action="${1:-build}"
if [[ $# -gt 0 ]]; then shift; fi
case "$action" in build|test) ;; *) echo 'Usage: scripts/build-fork.sh [build|test] [xcodebuild options]' >&2; exit 2;; esac
mkdir -p Mojito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp scripts/fork-packages.resolved Mojito.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
export KLIPY_API_KEY=''
python3 scripts/build_klipy_key.py
exec xcodebuild "$action" -project Mojito.xcodeproj -scheme Mojito \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "${MOJITO_DERIVED_DATA:-$HOME/Library/Caches/MojitoFork/Derived}" \
  -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- \
  MOJITO_INSTALL_DEV_APP=NO "$@"
