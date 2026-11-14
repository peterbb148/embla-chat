#!/bin/bash
# Build the iPhone Release target and run the scaffold launch test from a clean checkout.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(xcodebuild -version | head -n 1)" != 'Xcode 26.2' ]]; then
  echo 'Full Xcode 26.2 is required. Set DEVELOPER_DIR to its Contents/Developer directory.' >&2
  exit 1
fi

project=(-project EmblaChat.xcodeproj -scheme EmblaChat)
locked=(-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution)
mkdir -p build
xcodebuild -version
xcodebuild -resolvePackageDependencies "${project[@]}" \
  -onlyUsePackageVersionsFromResolvedFile 2>&1 | tee build/resolve.log
xcodebuild build "${project[@]}" "${locked[@]}" \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/device-build.log

# Create an isolated simulator and always remove it when this process exits.
device=$(xcrun simctl create EmblaChecks \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-2)
cleanup() {
  xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
  xcrun simctl delete "$device" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
# Result bundles must be new for each invocation; retain previous local evidence.
result_dir=$(mktemp -d "$PWD/build/test-run.XXXXXX")
xcodebuild test "${project[@]}" "${locked[@]}" \
  -destination "platform=iOS Simulator,id=$device" \
  -parallel-testing-enabled NO \
  -derivedDataPath build/SimulatorDerivedData \
  -resultBundlePath "$result_dir/Scaffold.xcresult" \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee build/simulator-test.log
