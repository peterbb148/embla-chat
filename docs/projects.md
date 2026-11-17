# Projects and explicit memory (#34)

The left sidebar contains Projects and All chats. Create a project with the plus button.
Long-press a chat and choose Move to project; No project removes its assignment. Opening a
project shows its chats and New chat in project. The normal top-level New Chat starts an
unassigned chat. Project assignment and each chat's draft survive restart.

## Save only what you choose

In a project chat, the bookmark action beside Copy opens Save to project memory. Edit the
prefilled message down to useful text, then Save. It never stores reasoning or extracts
facts automatically. Each note retains its source conversation and message IDs. Open the
project to inspect notes, open their source chat, edit text, or explicitly clear memory.
Edits retain attribution. Contradictory/outdated notes are the user's responsibility to
edit or clear; there is no invented automatic merge, summarizer or conflict-resolution agent.
Cancel closes an editor without changing stored memory. Atomic saving must finish before
an editor reports success. Failed writes leave the visible projects/notes unchanged and
show the error; chat-storage Retry remains available in Settings.

Notes apply only to chats assigned to that project. Moving a chat keeps its transcript,
summary and draft; notes explicitly retained in its old project stay there. Facts already
written in a transcript move with that chat. A memory source link can therefore point to
a chat that was subsequently moved, without transferring the retained note automatically.

## Context and limits

Project notes are serialized as JSON data and combined with the rolling chat summary in
one leading system message, as required by the pinned Embla chat template. Per-chat
compaction summaries stay separate in storage. Summary generation receives the older chat
transcript and prior chat summary, not an automatically extracted project-memory update.
Exact tokenizer counting and inference use the same project prefix. The composer ring
therefore includes project notes. All saved notes are included; oversized notes/contexts
produce an explicit error suggesting editing memory. Nothing is silently truncated or
substituted. The recent-exchange and summary/reply budgets are unchanged.

## Persistence and privacy

The local atomic archive adds `projects`, while each snapshot has an optional `projectID`.
The portable format-3 library includes chats, project definitions and manually saved notes.
Formats 1 (single chat) and 2 (history) are explicit supported migrations with no projects.
Invalid assignments and broken note-source references fail clearly. The existing
`EmblaChat/Chats/ActiveChat.json` path is retained, and Skills/Actions stay separate.
Older app builds cannot read format 3. Use the updated build on devices sharing a library.

The user chose **one global iCloud switch**, now covering chats, project memory and
[shared settings/readable MCP keys](settings-sync.md). Off remains the
default; all project edits stay local while Off. Consent explicitly names all saved chats,
summaries, project memory, settings and readable MCP keys. Drafts, device selection, folder permissions and model weights
stay local. Existing On archives without the current consent version are paused before
opening a provider. Settings asks the user to confirm the expanded scope and select the
folder again; only a successful preference save permits synchronization. Ordinary local
checkpoints cannot turn that paused state into new consent. Turning Off still stops new
app operations and keeps existing cloud files.

Conflict choices cover the whole chat/project/memory library and explicitly warn about
replacing all local chats, notes and drafts. There is no automatic transcript/note merge.
Local edits are detected through content fingerprints. Per-chat cloud controls remain #42.
Real multi-chat/project-memory personal-iCloud provider validation is explicitly deferred by
the user to unplanned #45, outside Epic 4. Fixtures/coordinated local files are not transfer proof.

## Validation

Package tests cover explicit save/edit/clear and source IDs, restart, assignment/draft
preservation, failed-write preservation, legacy format migration, scope renewal before
provider access, project-only inference input, token-count inclusion, and oversized-note
failure without truncation. Fixture inference/provider implementations are test-only.
Production simulator UI and opt-in real-host inference results are recorded separately when
completed. Host inference does not establish simulator Metal support or iPhone performance.

Local Xcode 27.2 package coverage and all eight production UI tests passed on the existing
"iPhone 17 Pro" / iOS 27.2. The UI project case creates a project, moves a chat, creates a
second project chat, switches back and restores the original draft/assignment after restart.
The final action-row layout also builds successfully. Visual note-editor validation is
recorded below separately from these automated results.

The opt-in real-model project-memory test passed on Apple M1 / macOS 26.7.3 in 38.55 seconds.
A real source conversation was explicitly retained as BLUE PENGUIN; a new chat in the same
project recalled it. A different project answered UNKNOWN. After an explicit edit and a fresh
controller/runtime session, a new project chat recalled RED FOX. Clearing notes made a new
chat answer UNKNOWN. These are real generated replies, not fixtures or response rewriting;
this is functional host evidence, not iPhone performance or simulator Metal inference.

Manual production-app inspection used one clearly labelled UI-only source chat, not model
output. The bookmark opened the editable source text and attribution. Typing followed by
Cancel kept zero notes; a subsequent Save persisted the exact edited text with matching
source chat/message UUIDs. From another project chat, Open source selected the original
fixture conversation. Clear showed an explicit source-chats-kept confirmation; Cancel kept
the note. Actual clearing is separately covered by package and real-model tests. Keyboard
capture was restored to Off, and app iCloud remained Off throughout. No extra simulator or
cloud provider access was used. The final local package run reports 124 tests and the final
simulator build passes; real-model checks are opt-in and reported separately above.

Review regressions: while expanded consent is paused, Choose iCloud folder stays enabled
and Sync now is disabled. Project edits invalidate cached library-conflict choices while
paused, so resuming recomputes choices using the new content. Parameterized edit/clear/move
cases failed against the original implementation and pass with this correction; choosing
the refreshed local version then resolves successfully without manual Sync now.
