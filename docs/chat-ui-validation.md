# Conversational UI validation (#25)

## Implemented behavior

The main screen is a chronological user/assistant transcript with a bottom composer,
Send/Stop, New Chat and Settings. Reasoning is expandable within the assistant turn.
Model download, integrity checking, storage deletion and last-response measurements
live in Settings rather than above the chat. Subsequent [chat polish](chat-polish.md)
adds native Markdown block rendering, selectable code, Copy and refined output-follow.
The observations below retain their historical source commits.

At the #25 acceptance milestone, each Send supplied all prior user turns and actual
nonempty assistant text/reasoning
through the real inference API. Interrupted, failed and limited responses stay visibly
marked. New Chat waits for the worker before clearing conversation and runtime context.
The composer locks while a confirmed reset drains, then focuses the new conversation;
expanded reasoning follows output under the same near-bottom guard as answer text.
No context is silently dropped when the budget is exceeded. This transcript is in memory;
compaction (#8) and persistence (#9) were unimplemented at that milestone. Subsequent
[compaction work](context-compaction.md) supplies a rolling summary plus recent turns
without deleting the visible transcript. The subsequent [local persistence work](chat-persistence.md) adds save/restore; optional
iCloud sync also shipped in PR #31. See the [working-version audit](working-version-validation.md).

## Local validation (2026-11-14)

- Xcode 27.2 unsigned iOS Release build passed.
- Core and presentation checks passed, including actual context-array assertions for
  follow-up messages, New Chat context reset, interruption states and wait-for-stop.
  Additional review regressions preserve earlier answers after rejected empty requests
  and allow New Chat to clear/unlock even when model storage setup is unavailable.
  A length-limit fixture also verifies partial text/reasoning stay marked as limited
  and enter the follow-up context before a subsequent response completes normally.
  The optional provider check was skipped in this fixture run; it remains a separate CI check.
- On the iPhone 18 Pro simulator with iOS 27.2, all three UI tests passed:
  `testModelControlsAreInSettings`, `testComposerFocusAndSendRequiresVerifiedModel`,
  and `testNewChatRequiresConfirmation`. The composer test explicitly observed the
  software keyboard after a tap and entered text. No model weights or fake responses
  were used by the UI tests.
- Local logs/results are under ignored `build/ChatUI-first.xcresult` and temporary logs.
  Hosted checks and review must be recorded against the final PR head before merge.

## Physical observations before the visual revision

On 2026-11-14, source c8d9577 was signed and installed on iPhone 17 Pro / iOS 27.2.1,
preserving the existing 5.62 GB verified model. The following were directly observed:

- Model controls and verified storage appeared in Settings. Opening and closing Settings
  preserved the draft.
- Device Hub Capture Keyboard off alone still showed only a small input toolbar.
  Device > Keyboard > Toggle Software Keyboard displayed the full keyboard. Done
  dismissed it, and tapping Message showed it again. Mac-injected text could hide the
  on-screen keyboard while leaving its accessory toolbar visible.
- First message: Remember my secret phrase blue penguin. The actual response acknowledged
  blue penguin. Follow-up: What secret phrase did I give you. Actual answer:
  The secret phrase you gave me is "blue penguin". Both user and assistant turns stayed
  visible in the transcript.
- On 2026-11-15 the user reported that offline use works well and supplied physical
  screenshots with the software keyboard displayed. The user requested a further
  visual revision to match the ChatGPT reference; those screenshots show the prior UI.

## ChatGPT-reference visual revision (2026-11-15)

The composer is now one taller rounded card, with its Send/Stop button inside the lower
row and text above. A keyboard-hide icon replaces the separate Done accessory row.
User messages use neutral bubbles; assistant answers have no repeated Embla/sparkle
label; thoughts are muted and expandable. The header uses a compact Embla capsule,
Settings and New Chat. No attachment, voice or Work controls are shown because those
features are outside scope. The transcript has a separate clipped viewport above the
composer so text cannot appear below the input while the keyboard changes height.

The final proportions passed all three simulator UI tests under Xcode 27.2 / iOS 27.2.
The composer test explicitly checks that both the input and Send control are above the
keyboard and that the separate Done button is absent. The settled keyboard/card layout
was also visually inspected in Device Hub with a typed draft. Final-head hosted checks
and Copilot review must pass before merge.

## Revised design installed and accepted (2026-11-15)

After the user explicitly approved the app restart and clearing the unsaved chat,
source 07adec64c261ce84ffb46edce307e292959d7c9e was signed, installed and launched on
the physical iPhone 17 Pro / iOS 27.2.1. The existing verified model was reused without
another download.

The following were directly observed on the physical phone:

- The compact header, single rounded input card and neutral user bubble appeared.
- The full Danish software keyboard appeared while entering Hej med dig. Send was
  inside the card above the keyboard, with no separate Done accessory row.
- Sending Hej med dig produced the real response Hej! Hvordan kan jeg hjælpe dig i dag?
  The response appeared in the simplified assistant row while the composer remained
  separate from the transcript.
- The user continued testing and reported Looks perfect, accepting the revised design.
  Further manual conversation content was not recorded in repository evidence.

Implementation head 07adec6 passed hosted validation in run
[43690449574](https://github.com/peterbb148/embla-chat/actions/runs/43690449574), and
Copilot reviewed that exact head with no open code findings or unresolved threads.
The final evidence-only commit also requires review/checks before merge.

Stop/reset/error/limited-response sequencing remains covered by the controller
regressions; the earlier inference milestone also has recorded physical lifecycle
observations. Every lifecycle interleaving was not repeated for this cosmetic revision.
The subsequent compaction and persistence changes merged in PRs #30 and #31.
The [working-version audit](working-version-validation.md) records integrated acceptance
for #5 and #6. Broader polish and release validation remain in #18 and #7; this historical
visual acceptance does not establish final release readiness.
