# Chat persistence (#9)

## Implementation checkpoint

Local persistence is integrated on the issue branch; optional iCloud access is still pending.
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

## Remaining implementation

- Provide one app-wide opt-in setting in Settings. Local-only remains the default.
- Use the native Files picker to select/create `iCloud Drive/EmblaChat` in the user's
  personal account. Store the security-scoped bookmark locally and coordinate file access.
- Make actual iCloud upload/download status explicit; a successful file write alone is not
  remote persistence evidence. Stop future writes and pending app operations when disabled.
- Detect changed revisions and unresolved document versions. Present conflicting copies for
  an explicit choice; never silently overwrite a newer chat or restore stale pre-reset data.
- Verify app relaunch/restoration and opt-in/out on the iPhone 17 Pro simulator. Verify real
  personal-iCloud transfer/restoration separately; fixtures do not prove cloud behavior.
- Later per-chat storage choices and iPad/Mac clients remain future work. The current scope
  is one active chat, without an archive or chat list.

Apple's supported APIs: [directory access and bookmarks](https://developer.apple.com/documentation/uikit/providing-access-to-directories),
[document-based iCloud access](https://developer.apple.com/documentation/uikit/uidocumentbrowserviewcontroller),
and [document conflict handling](https://developer.apple.com/documentation/uikit/uidocument).
