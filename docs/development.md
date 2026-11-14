# Development

## Current build blocker

The selected upstream revision fails iOS compilation in `ModelStore.swift` because
`homeDirectoryForCurrentUser` is unavailable. The scaffold has not yet passed its
hosted build or launch test. A one-line runtime fix is prepared; publishing a fork
is awaiting authorization. See [runtime integration](runtime-integration.md).

## Requirements

Use full Xcode 26.2 (including its iOS 26.2 simulator runtime) on a supported Mac.
Command Line Tools alone cannot build this iOS application. The deployment target
is iOS 18; the initial app targets iPhone. iPad and Mac apps are later milestones.

The checked-in `EmblaChat.xcodeproj` is the source project; no project generator is
required. Open it in Xcode, select the shared `EmblaChat` scheme and an iPhone
simulator, and Run. The current screen explicitly identifies the scaffold stage.
The Swift module is `EmblaChatApp` to avoid colliding with the upstream `EmblaChat`
package product. Both `EmblaMetal` and `EmblaChat` are linked at the exact revision
recorded in [runtime integration](runtime-integration.md).

## Build and launch validation

Select full Xcode for the current shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
xcodebuild -resolvePackageDependencies -project EmblaChat.xcodeproj -scheme EmblaChat
xcodebuild test -project EmblaChat.xcodeproj -scheme EmblaChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

The UI test launches the app and asserts the scaffold message. It does not load
model weights, compile runtime Metal kernels at execution, or prove physical-device
inference. The scaffold workflow runs this launch check on hosted macOS with Xcode
26.2 and uploads its result bundle. Reproducible device builds and broader CI checks
are tracked in #16.

## Signing and resources

For a physical iPhone, select your own development team under Signing & Capabilities,
choose a unique bundle identifier if needed, enable Developer Mode on the phone,
and Run with that phone selected. No team or signing credentials are committed.
Do not commit personal signing changes. This stage does not request iCloud or
increased-memory entitlements. Model setup will be added in Epic 2.

SwiftPM copies upstream Metal kernel and web resource bundles; preserve them.
The app also bundles both upstream license notice files from `third-party/`.
Model weights and local build/user state are ignored by Git.
