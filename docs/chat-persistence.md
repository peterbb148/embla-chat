# Chat persistence (#9)

## Implementation checkpoint

Local persistence and the optional iCloud Drive flow are integrated on the issue branch.
Real iCloud Drive transfer/restoration has been validated on an iPhone 17 Pro; see the
separate physical-provider evidence below.
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

Simulator UI checks include terminating/relaunching the production app and restoring a draft.
Simulator UI checks do not claim real model inference or actual cloud transfer.

## Optional iCloud Drive flow

Settings has one global default-off switch, explicit consent, and the native Files folder
picker. The user selects/creates `iCloud Drive/EmblaChat`; the app validates that the chosen
folder is an iCloud folder named EmblaChat and retains its security-scoped bookmark locally.
Within that root, `Chats/ActiveChat.json` contains the transcript, summary and reconstruction metadata;
model weights, local folder permissions and unsent drafts are excluded.
The separate `Skills` directory is reserved for portable skill folders in #27. Chat operations
leave its contents untouched; skill discovery/execution is not implemented yet. See the
[storage layout](storage-layout.md).

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

On 2026-11-15, all 82 package tests pass, including parameterized consent and sync-base cases.
These include
coordinated temporary-file tests,
explicit simulated cloud-provider tests for consent/disable/stale-read/conflict policies, and
controller tests combining real local files with simulated remote changes. All five iPhone
17 Pro / iOS 27.2 simulator UI tests pass, including opt-in cancellation and local draft
restoration. Hosted iOS build/launch checks passed for the physically tested commit
`0b92dd4ff4a0cb57f6197f5815933dd2cc607586`
([run 43713175710](https://github.com/peterbb148/embla-chat/actions/runs/43713175710)).
These automated tests do not prove real cloud transfer.

Gated regressions cover preference persistence before the first provider operation, disabling
while opt-in saving is pending, and failed opt-in save/retry without provider access before
consent becomes durable. They also verify that lifecycle resume/foreground callbacks cannot
bypass the pending consent save. The provider
is constructed only after that save succeeds; a separate configuration identity lets ordinary
lifecycle pauses preserve the pending opt-in while disabling/changing settings supersedes it.
Ordinary checkpoints inherit cloud settings from the preceding successful archive write,
rather than capturing an in-flight opt-in. Only an explicit preference write can commit an
enable request; a failed consent save cannot be resurrected by a later draft checkpoint.
The committed settings advance inside the serial writer only after saving succeeds. A gated
regression fails the preference save once, lets the queued checkpoint succeed, then reopens
the saved archive and verifies iCloud stays off with no provider reads/writes.
Other regressions hold actual local replacement writes open to verify
preference saves cannot resurrect the old conversation after either New Chat or cloud restore.
An explicit completion barrier covers both replacement paths. Unchanged polls avoid rewriting
already committed metadata. Failed sync-base writes stay pending and are retried even if the
next poll sees identical content; only a successful save in the current generation clears that
pending state. Tests reproduce failures after upload, download and conflict resolution, then
verify retry and reopening accept a later remote-only edit without an unnecessary conflict.
A real local-archive regression also covers storage Retry followed by Sync now.
Retry recreates a missing local store. The UI reset helper waits for an enabled,
empty composer rather than a disabled New Chat button, which also describes an active reset.
The cached identity of a replacement advances only after its archive save succeeds. A failed
cloud restore or New Chat save leaves the old visible conversation's fingerprint intact.
Real-file regressions reproduce both identity changes without the fix, then verify local Retry
and Sync now accept the remote-only update without inventing a local edit/conflict.
Explicit provider fixtures now supply multiple unresolved copies: automatic writes stay
blocked, every distinct copy is offered, explicit selection resolves the copies, and a newly
arrived copy invalidates the old choice until refreshed. A coordinated temporary-file test
also rejects a mismatched expected conflict fingerprint set without overwriting the document.
Model deletion remains available when a corrupt or inaccessible chat prevents restoration,
allowing storage to be reclaimed without altering the chat archive. A real-file regression
verifies model bytes are deleted while the corrupt conversation remains intact. The lifecycle
consent and deletion regressions reproduce the original failures with their fixes removed.

## Physical iCloud Drive evidence (2026-11-15)

The production Release app at `0b92dd4` was installed on an iPhone 17 Pro / iOS 27.2.1.
The following used the real Files provider and a Mac, with no substitute cloud provider:

- Created `iCloud Drive/EmblaChat` through Files, selected it through Embla's native folder
  picker, and observed `ActiveChat.json` arrive on the Mac.
- A coordinated Mac edit supplied three clearly labelled synthetic storage-test messages and
  a summary with boundary 2. The phone restored them. A copied app archive matched the cloud
  snapshot exactly, including message IDs, summary and boundary. The synthetic assistant text
  and summary were storage fixtures, not generated inference results.
- With app sync disabled, restarted the app and restored the conversation, summary and local
  draft. The real local Embla model then answered the summary-recall prompt with
  `EMBLA-CLOUD-17`. Its completed answer was saved locally; the cloud document stayed at three
  messages while the local conversation had five. Drafts and folder bookmarks were absent
  from the portable document.
- Reconnecting the folder showed the five-message device chat and three-message cloud chat
  as explicit choices. Cancel preserved both. Confirming the device copy uploaded the complete
  five-message snapshot; its contents and IDs matched on the Mac. Settings reported Synced.
- Restarted the app with sync enabled. The saved folder permission worked without another
  picker and Settings again reported Synced.
- Temporarily renamed only the test cloud document, preserving its contents. Embla showed the
  missing-previously-synchronized-chat error and retained the local chat. Restoring the file
  recovered synchronization and cleared the error.
- Cancelled New Chat preserved the visible conversation. Confirmed New Chat cleared messages,
  summary and summary boundary locally and in the cloud; the Mac document matched the new
  empty phone snapshot. Settings reported Synced. App sync was then disabled, keeping the
  cloud file and downloaded model.

This proves real transfer, content divergence/choice, persistence and missing-file recovery.
It does not claim forced account/network failures or an OS-generated `NSFileVersion` duplicate
conflict. Transfer failures and unresolved-copy policies use explicit provider fixtures;
the operating system's creation/enumeration of conflict versions has not been forced in a test.
Personal account
identifiers, authentication state and system Drive settings are excluded from public evidence.
Do not run UI automation during a user handoff.

The requested `Chats`/`Skills` separation was verified in a signed Release follow-up at
`0a8287f` on the same physical iPhone. The original test document was moved intact to
`Chats/ActiveChat.json`; Files showed both sibling folders. A new coordinated Mac edit of
the labelled three-message fixture and boundary-2 summary restored exactly on the phone,
as verified against its copied local archive. Confirmed New Chat then uploaded an empty
snapshot with matching IDs and cleared summary to the new path. The old root-level file
remained absent, Settings reported Synced, and app sync was disabled afterward. The model
remained stored locally. This follow-up proves the changed path; the earlier recall,
divergent-copy and missing-file tests above were not repeated for this path-only change.
The subsequent consent-lifecycle, checkpoint, sync-base and deletion recovery fixes have focused package regressions;
the physical cloud sequence was not repeated for those control-flow changes.

Final-head Copilot review, fixes/re-review and hosted checks are required before merge.

Developer Program-dependent capabilities/distribution are deferred to #32. The current
Files-based storage design does not use CloudKit or an app-owned iCloud container. Later
per-chat storage choices and iPad/Mac clients remain future work; there is one active chat.

Apple's supported APIs: [directory access and bookmarks](https://developer.apple.com/documentation/uikit/providing-access-to-directories),
[document-based iCloud access](https://developer.apple.com/documentation/uikit/uidocumentbrowserviewcontroller),
and [document conflict handling](https://developer.apple.com/documentation/uikit/uidocument).
