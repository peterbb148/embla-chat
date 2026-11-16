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
Feature tests accompany the implemented features. The [working-version audit](working-version-validation.md)
preserves the #6 checkpoint; [Epic 4 delivery](epic4-validation.md) maps current coverage
and the limits of earlier physical evidence.

## Reuse an existing local simulator

On this development Mac, use the existing **iPhone 17 Pro**. Do not run the CI entry
point locally merely to test the UI: it creates an isolated simulator and requires the
hosted Xcode version. List existing devices and select its ID; never create a replacement
just because a result bundle or build directory is new.

The full UI suite is a **model-unconfigured readiness scenario**. Before running it:

- Embla's global iCloud switch must be **Off**. A production launch with an existing On
  preference and folder grant can synchronize.
- No downloaded/verified model may be available to this simulator app. The tests require
  the Download model control and disabled Send/counting before setup; installed weights
  change those expected controls even when iCloud is Off.
- Local quick actions must use the starter configuration in [examples/actions.json](../examples/actions.json).
  The action-card test expects those labels and editable prompts.

Hosted CI starts in that state. Reusing a simulator does not recreate it automatically.
If existing weights or custom actions are present, stop and arrange authorized state
preparation while preserving them. These instructions do not authorize deleting weights,
overwriting a configuration, resetting app data or creating another simulator.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun simctl list devices available
# Copy the existing iPhone 17 Pro ID from the list above.
embla_simulator_id='EXISTING-IPHONE-17-PRO-UUID'
swift test --force-resolved-versions
xcodebuild test -project EmblaChat.xcodeproj -scheme EmblaChat \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$embla_simulator_id" \
  -derivedDataPath build/Epic4Simulator -parallel-testing-enabled NO \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO
```

Production UI tests use actual app storage and create/retain test chats and drafts.
The tests do not sign into accounts, grant new folder access or generate model replies. Real-provider checks
remain deferred to #45; use a dedicated explicitly authorized test folder for those checks.
UI tests and unsigned device builds require no Developer Program membership. No simulator
reset, new device or personal-account change is needed. Reuse the derived-data directory;
add a unique `-resultBundlePath` only when an additional evidence bundle is needed.

## Verified scaffold evidence

[Scaffold run 43582094191](https://github.com/peterbb148/embla-chat/actions/runs/43582094191)
built and launched commit `43bf527` under Xcode 26.2 with the patched runtime.
`LaunchTests.testScaffoldLaunches` passed with zero failures. The expanded Release
build and clean-checkout checks subsequently passed; current evidence is linked in
[the working-version audit](working-version-validation.md).

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

EmblaPresentation owns the active transcript, checkpoints it to local storage, and serializes real model
requests. The main view shows user messages, assistant responses, expandable reasoning,
a bottom-anchored multiline composer, Send/Stop and confirmed New Chat. Model download,
verification, storage deletion and last-response measurements are in Settings. Opening
Settings does not reset the conversation or start another readiness check.

Every Send reconstructs inference context from explicit project memory, the rolling summary
and recent transcript. The full visible transcript remains saved.
The real tokenizer triggers local compaction before the context fills; the visible transcript
is retained. Interrupted, failed and length-limited responses remain explicitly marked.
See [compaction](context-compaction.md) for budgets, cancellation and device evidence.
There is no silent truncation or substitute model. Local persistence now restores the transcript, summary and draft after process exit;
see [chat persistence](chat-persistence.md) for checkpoint/error behavior, simulator tests and
real iPhone/Mac iCloud transfer/restoration evidence. Optional iCloud is off by default.
PR #31 merged the implementation after final-head review, CI and physical validation.

The composer uses native SwiftUI focus and a vertical layout: the transcript has its
own clipped scrolling region above a single rounded input card. Send/Stop and a keyboard
hide control are inside that card. There is no separate keyboard Done accessory row.
Container resizing follows the latest message when the reader was already at the bottom;
scrolling up still pauses output-follow. Neutral user bubbles and muted expandable
thoughts follow the user's ChatGPT visual reference without adding unsupported controls.

Device Hub can hide the software keyboard even with Capture Keyboard off. During the
physical test, Device > Keyboard > Toggle Software Keyboard showed the full keyboard;
dismissing and tapping Message brought it back. Mac-injected typing can switch back to
hardware-keyboard behavior. Check the keyboard on the physical phone as well as the
mirrored view rather than adding an app-level forced-keyboard workaround.

Idle sleep is disabled only during foreground work. Inactivity requests cancellation;
backgrounding cancels and unloads once the worker drains. New Chat uses the same stop/wait
sequence before archiving the old transcript/draft and resetting inference context. The composer
is disabled until navigation is saved. The left sidebar restores each chat’s summary and draft;
Settings is inside that sidebar. Focus returns when the selected conversation is ready.
Expanded reasoning participates in scroll-follow while the reader remains near the bottom.
Model deletion never
clears the conversation.

Presentation tests use explicit fixture backends to verify actual context arrays,
interruption states, reset and lifecycle sequencing. The app's public constructor always
selects EmblaRuntime; there is no app mock mode. Physical model acceptance from Epic 2
is in [device validation](device-validation.md); new UI/device observations belong to #25.

## Skills and MCP validation

[Skills and MCP](skills-and-tools.md) records protocol/permission boundaries and separates
fixture tests from actual-model/network evidence. Package tests include a loopback-only
Python HTTP/SSE fixture with synthetic data; Python 3 must be available through `env`.
It does not expose a public listener or run copied skill scripts. Production UI tests add
and remove a uniquely named no-token test server without connecting it. They preserve
other configured servers and credentials.

Real-model tests are opt-in and must run separately to avoid loading multiple GPU engines:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export EMBLA_REAL_MODEL_ROOT=/absolute/path/to/verified-model-storage-root
EMBLA_REAL_PRODUCTION_TOOLS=1 swift test --filter realProductionToolLoopUsesRegisteredPublicTimeAndPersistsTheReturnedFact
EMBLA_REAL_SKILL=1 swift test --filter realSelectedPortableSkillChangesTheModelsActualAnswer
```

The first command contacts `https://time.now/mcp` with only the public Copenhagen timezone
argument through the registered/enabled test tool. Do not substitute private chat data or
credentials in a public test. The second copies an isolated synthetic standard skill and
checks its observed effect on actual model output. Neither command is an iPhone benchmark,
a real iCloud transfer test or a guarantee of arbitrary skills/server compatibility.
