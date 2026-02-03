#!/usr/bin/env bash
set -euo pipefail

echo "SpotMap Swift environment check"
echo "--------------------------------"

missing=0

check_cmd() {
  local cmd="$1"
  local hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "✅ $cmd: $(command -v "$cmd")"
  else
    echo "❌ $cmd: not found"
    echo "   -> $hint"
    missing=1
  fi
}

check_cmd "xcodebuild" "Install Xcode and run: xcode-select -s /Applications/Xcode.app"
check_cmd "xcrun" "Install Xcode command line tools."
check_cmd "swift" "Install Xcode or Swift toolchain."

echo
if [[ "$missing" -eq 0 ]]; then
  echo "All required tools are available."
  echo "Try building:"
  echo "  xcodebuild -project \"Spotmap Buildmain/spotmap.xcodeproj\" -scheme spotmap -destination \"generic/platform=iOS\" build"
else
  echo "One or more tools are missing. See docs/SwiftEnvironment.md for setup steps."
fi
