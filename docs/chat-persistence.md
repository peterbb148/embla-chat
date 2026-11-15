# Chat persistence (#9)

## Implementation checkpoint

The storage foundation is implemented on the issue branch; the app does not yet call it.
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
These are storage tests, not evidence of a working in-app save flow or actual iCloud sync.

## Remaining implementation

- Wire initial restore, draft/stream checkpoints, final response/summary saves and confirmed
  New Chat into the presentation controller, with visible saving/error states.
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
