# Chat persistence (#9)

## Implementation checkpoint

Local persistence and the optional iCloud Drive flow are integrated on the issue branch.
Actual personal-iCloud transfer/restoration remains unverified.
`ConversationSnapshot` preserves stable message IDs, response states, the rolling summary,
and its transcript boundary in a versioned document. `ConversationArchive` is the separate
device-local envelope for the draft, global default-off cloud preference, folder permission
bookmark, and synchronization base revision. Drafts and folder permissions are not part of
the portable cloud document.

`ConversationStore` writes local archives atomically and excludes its directory from iCloud
backup, honoring local-only privacy as well as the future app-managed sync opt-in. On iOS,
data protection keeps files unavailable until the device has first been unlocked after boot.
Monotonic local save sequences reject delayed writes after New Chat. Incompatible/corrupt
archives and filesystem failures remain errors; they never become a fabricated empty chat.
Restoration converts streaming replies to interrupted replies without restarting generation.

Package tests cover round-trip state/IDs, default-off preference, backup exclusion, partial
reply recovery, stale writes after reset, malformed/unsupported data, and storage failures.
Controller tests additionally exercise reopening a completed/compacted chat, using its restored
summary for the next reply, recovering partial output, protecting corrupt files, and preserving
the visible chat when a reset save fails. These use fixture inference backends and real local
files; they are not proof of model inference or actual iCloud sync.

## In-app local behavior

Startup opens and validates the saved chat before enabling the composer. Submitted messages
are saved before inference starts; streaming output and draft changes are checkpointed at
roughly 500 ms intervals, with explicit final/background saves. Abrupt termination can lose
changes after the latest completed write. Settings reports pending saves, completed local
saves, or an error with Retry. A completed file write, rather than a queued checkpoint, is
required before reporting Saved. A storage failure blocks new generation until saving succeeds.

Confirmed New Chat queues a durable empty replacement after older writes and only then
clears the visible transcript/summary. A failed reset leaves the current chat visible. The
local envelope keeps unsent drafts on this device; they are not part of the cloud document.

On 2026-11-15, all 47 package tests passed and all four iPhone 17 Pro / iOS 27.2 simulator
UI tests passed. The latter include terminating/relaunching the production app and restoring
a draft. This does not claim simulator inference, cloud account access or cloud transfer.

## Optional iCloud Drive flow

Settings has one global default-off switch, explicit consent, and the native Files folder
picker. The user selects/creates `iCloud Drive/EmblaChat`; the app validates that the chosen
folder is an iCloud folder named EmblaChat and retains its security-scoped bookmark locally.
The portable `ActiveChat.json` contains the transcript, summary and reconstruction metadata;
model weights, local folder permissions and unsent drafts are excluded.

`ICloudConversationStore` resolves the granted bookmark for each operation, coordinates file
access with `NSFileCoordinator`, validates documents, and checks content fingerprints before
replacing data. Unresolved `NSFileVersion` copies are surfaced as conflicts. A confirmed choice
marks only the versions observed during that coordinated operation resolved. There is no
unconditional overwrite or corrupt-file-to-empty recovery.

On first connecting to an existing document, the user chooses which chat to keep. Later,
a shared content fingerprint distinguishes unchanged state from local/remote edits. A remote
change can replace the local chat only when local content is unchanged and no unsent draft
would be discarded. Concurrent edits or unresolved versions require an explicit choice.
Choosing an iCloud copy confirms replacing this device's chat and unsent draft. If a chat
changes while a cloud read is pending, that old result cannot restore the previous conversation.
New Chat invalidates in-flight cloud work before starting its durable local reset, then queues
fresh synchronization. An earlier upload whose acknowledgement was interrupted can require an
explicit conflict choice; it cannot queue the old conversation after the reset and resurrect it.

No provider is opened or called while the preference is disabled, including when an old
bookmark remains stored. Disabling cancels pending app operations and persists the choice;
it keeps existing cloud files. Operations already handed to iCloud Drive may finish transferring.
Foreground synchronization runs after local chat operations and checks periodically; inactivity
pauses app-managed operations. Local checkpoints and unloading continue in the background, but
neither can restart cloud access until the app becomes active. Provider-reported upload and
download errors remain errors rather than being reported as indefinitely pending uploads. Failures remain visible in Settings and local storage stays
independent. A local/provider write reports pending upload; only the provider's uploaded state
for matching content reports Synced. Missing/revoked permissions and missing previously-synced
files remain explicit errors rather than silently selecting another location.

## Validation checkpoint and remaining work

On 2026-11-15, all 70 package tests pass. These include coordinated temporary-file tests,
explicit simulated cloud-provider tests for consent/disable/stale-read/conflict policies, and
controller tests combining real local files with simulated remote changes. All five iPhone
17 Pro / iOS 27.2 simulator UI tests pass, including opt-in cancellation and local draft
restoration. These tests do not prove iCloud authentication, transfer or cross-device conflicts.

The production native Files picker and consent flow have been exercised manually on the
simulator. Actual iCloud folder access, transfer, restoration and cross-device conflicts still
require live validation. Personal account identifiers, authentication state, and system Drive
settings are not part of public test records. Do not run UI automation during a user handoff.

The first Copilot review found reset/upload, stale conflict-callback, transfer-error and
background-resume gaps. Fixes now have deterministic package regressions, including holding a
real reset archive write's completion while the old visible chat and cloud upload still exist.
The next review also identified stale conflict choices after New Chat. Reset now clears those
choices while paused, then reevaluates them against the reset conversation when synchronization
resumes. A regression verifies no manual Refresh is needed. A further review found that an
opt-out preference write could capture the old visible chat during a durable reset. Preference
saves now await the reset operation before capturing the published conversation; the gated
regression reproduces the old transcript resurrection without the fix. Retry also recreates a
missing local store after initialization failure, preserving any existing archive. Preference
saves await an explicit replacement-completion barrier for both New Chat and cloud restoration;
a cloud restore can be active without a model-operation task. Unchanged cloud polls no longer
rewrite the local archive: cloud metadata is saved when the shared base changes. Both additional
regressions reproduce their respective failures with these fixes removed. The launch-test reset
helper now waits for an enabled, empty composer; a disabled New Chat button alone also describes
an in-progress reset. Fresh review and hosted checks remain pending.

Remaining gates for #9:

- Verify persistent folder permission and actual personal-iCloud upload/download/restoration,
  including the transcript and summary, in an authenticated test environment.
- Record provider account/network errors and real conflict behavior separately from fixtures.
- Complete final-head Copilot review, fixes/re-review, and hosted checks before merge.

Developer Program-dependent capabilities/distribution are deferred to #32. The current
Files-based storage design does not use CloudKit or an app-owned iCloud container. Later
per-chat storage choices and iPad/Mac clients remain future work; there is one active chat.

Apple's supported APIs: [directory access and bookmarks](https://developer.apple.com/documentation/uikit/providing-access-to-directories),
[document-based iCloud access](https://developer.apple.com/documentation/uikit/uidocumentbrowserviewcontroller),
and [document conflict handling](https://developer.apple.com/documentation/uikit/uidocument).
