# Conversational UI validation (#25)

## Implemented behavior

The main screen is a chronological user/assistant transcript with a bottom composer,
Send/Stop, New Chat and Settings. Reasoning is expandable within the assistant turn.
Model download, integrity checking, storage deletion and last-response measurements
live in Settings rather than above the chat. Basic assistant Markdown uses native
SwiftUI Text rendering; broader rendering/copy/accessibility polish remains #18.

Each Send supplies all prior user turns and actual nonempty assistant text/reasoning
through the real inference API. Interrupted, failed and limited responses stay visibly
marked. New Chat waits for the worker before clearing conversation and runtime context.
The composer locks while a confirmed reset drains, then focuses the new conversation;
expanded reasoning follows output under the same near-bottom guard as answer text.
No context is silently dropped when the budget is exceeded. This transcript is in memory;
compaction (#8) and iCloud persistence/restoration (#9) remain unimplemented.

## Local validation (2026-11-14)

- Xcode 27.2 unsigned iOS Release build passed.
- Core and presentation checks passed, including actual context-array assertions for
  follow-up messages, New Chat context reset, interruption states and wait-for-stop.
  Additional review regressions preserve earlier answers after rejected empty requests
  and allow New Chat to clear/unlock even when model storage setup is unavailable.
  The optional provider check was skipped in this fixture run; it remains a separate CI check.
- On the iPhone 18 Pro simulator with iOS 27.2, all three UI tests passed:
  `testModelControlsAreInSettings`, `testComposerFocusAndSendRequiresVerifiedModel`,
  and `testNewChatRequiresConfirmation`. The composer test explicitly observed the
  software keyboard after a tap and entered text. No model weights or fake responses
  were used by the UI tests.
- Local logs/results are under ignored `build/ChatUI-first.xcresult` and temporary logs.
  Hosted checks and review must be recorded against the final PR head before merge.

## Required physical checks

These remain pending. The Mac was locked and the phone disconnected when visual/device
validation was attempted; simulator success is not physical-phone evidence.

1. Install the reviewed build on the unlocked iPhone without deleting its verified model.
2. Turn Device Hub Capture Keyboard off. Tap the composer directly on the phone and
   verify the software keyboard appears, text is visible, and Send remains above it.
   Capture Keyboard can behave like an attached hardware keyboard; do not force the
   software keyboard when a hardware keyboard is deliberately in use.
3. Verify that the opening screen has the transcript/composer and model administration
   is reachable only through Settings. Close Settings and confirm the draft survives.
4. Send a fresh factual instruction such as Remember my secret phrase blue penguin,
   then ask What secret phrase did I give you. Record the real second answer and
   confirm both turns remain visible, establishing actual multi-turn context use.
5. Start a longer response, stop it, and send another message. Check interrupted output
   remains marked and no stale stream enters the next assistant turn.
6. Check New Chat Cancel preserves messages/draft, while confirmation clears them.
   Background/reopen must stop/unload without silently restarting a response.
7. Inspect readable scrolling, keyboard dismissal and Settings on the actual device;
   report any visual or runtime defects before closing #25.
