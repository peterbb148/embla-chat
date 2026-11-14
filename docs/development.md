# Development

## Runtime compatibility patch

The app pins the [runtime fork](https://github.com/peterbb148/embla-metal/commit/0c8caaa3616372482d047fa9e953ea656cb34588)
with a single iOS compilation fix. The original revision calls an API unavailable
on iOS. Build and simulator launch validation must pass with this corrected pin.
See [runtime integration](runtime-integration.md) for the exact change and provenance.

## Requirements

The reproducible hosted baseline is full Xcode 26.2 with its iOS 26.2 simulator runtime.
Local Xcode 27.2 is also used for signed iPhone validation; select it explicitly with
`DEVELOPER_DIR` rather than using Command Line Tools.
Command Line Tools alone cannot build this iOS application. The deployment target
is iOS 18; the initial app targets iPhone. iPad and Mac apps are later milestones.

The checked-in `EmblaChat.xcodeproj` is the source project; no project generator is
required. Open it in Xcode, select the shared `EmblaChat` scheme and an iPhone
simulator, and Run. The current screen is a conversation with a bottom composer. Model download and
verification controls are in Settings.
The app target, product, and Swift module are `EmblaChatApp` to avoid colliding
with the upstream `EmblaChat` package target. The shared scheme remains `EmblaChat`,
and the app display name remains Embla Chat. The UI test explicitly references
the app target by ID. Both `EmblaMetal` and `EmblaChat` are linked at the exact revision
recorded in [runtime integration](runtime-integration.md).

## Build and launch validation

From a clean checkout, select full Xcode and run the same entry point as CI:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
./scripts/check.sh
```

The script fails if the selected toolchain is not Xcode 26.2. Install the iOS 26.2
simulator runtime through Xcode before running it. It resolves only the checked-in
`Package.resolved` revision, builds the unsigned Release target for generic iOS,
runs the shared core tests (including inference lifecycle fixtures), then creates an isolated iPhone 17 Pro simulator and
runs the chat/settings UI tests. Simulator
cleanup runs on exit. Local signing credentials and model weights are not needed.

UI tests check that model controls are in Settings, tapping the composer displays
a software keyboard, Send requires a verified model, and New Chat confirmation preserves
or clears a draft. They do not load
model weights, compile runtime Metal kernels at execution, or prove physical-device
inference. The unsigned device build checks compilation/linking for actual iOS,
including copied SwiftPM resources, but does not prove installation or inference.

The workflow runs on PRs, main pushes, and manual dispatch. It uses Xcode 26.2 on
`macos-15`, pinned action revisions, and the same script without dependency caches.
Logs and result bundles are uploaded for seven days. Local output is under `build/`;
result bundles get unique directories so repeated checks preserve earlier results.
The PR and main checks must pass independently; CI never downloads model weights.
An additional provider check downloads only the pinned 5 KB config file; see
[model storage](model-storage.md) for details.
Feature-level tests will accompany their implementations in later issues (#6).

## Verified scaffold evidence

[Scaffold run 43582094191](https://github.com/peterbb148/embla-chat/actions/runs/43582094191)
built and launched commit `43bf527` under Xcode 26.2 with the patched runtime.
`LaunchTests.testScaffoldLaunches` passed with zero failures. The expanded Release
build and clean-checkout CI require their own successful run before #16 closes.

## Signing and resources

For a physical iPhone, select your own development team under Signing & Capabilities,
choose a unique bundle identifier if needed, enable Developer Mode on the phone,
and Run with that phone selected. No team or signing credentials are committed.
Do not commit personal signing changes. This stage does not request iCloud or
increased-memory entitlements. Model setup is documented in [model storage](model-storage.md).

SwiftPM copies upstream Metal kernel and web resource bundles; preserve them.
The app also bundles both upstream license notice files from `third-party/`.
Model weights and local build/user state are ignored by Git.

The root Swift package and Xcode project both pin the same runtime revision.
Their lockfiles are checked in; test/build commands enforce resolved versions.
See [inference API](inference-api.md) for session ownership and device evidence limits.

## Conversational screen and settings

EmblaPresentation owns the active in-memory transcript and serializes real model
requests. The main view shows user messages, assistant responses, expandable reasoning,
a bottom-anchored multiline composer, Send/Stop and confirmed New Chat. Model download,
verification, storage deletion and last-response measurements are in Settings. Opening
Settings does not reset the conversation or start another readiness check.

Every Send supplies the visible conversation's user messages and actual nonempty
assistant output/reasoning to the upstream template. Interrupted, failed and length-limited
responses remain explicitly marked. Empty response rows do not become invented model
content. No turn is silently trimmed to fit the context limit; the API reports the budget
error. Automatic compaction (#8) and iCloud restoration (#9) are still pending. The active
transcript and draft are lost when the process exits in this milestone.

The composer uses native SwiftUI focus and a bottom safe-area inset so the software
keyboard has space. Device Hub's Capture Keyboard behaves as an attached hardware
keyboard and can suppress the on-phone keyboard. Turn capture off when checking the
software keyboard, and also verify by tapping directly on the physical phone. Do not
force a software keyboard over a deliberately attached hardware keyboard.

Idle sleep is disabled only during foreground work. Inactivity requests cancellation;
backgrounding cancels and unloads once the worker drains. New Chat uses the same stop/wait
sequence before clearing transcript, draft and inference context. Model deletion never
clears the conversation.

Presentation tests use explicit fixture backends to verify actual context arrays,
interruption states, reset and lifecycle sequencing. The app's public constructor always
selects EmblaRuntime; there is no app mock mode. Physical model acceptance from Epic 2
is in [device validation](device-validation.md); new UI/device observations belong to #25.
