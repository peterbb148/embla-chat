# Automatic context compaction

Issue #8 adds a rolling on-device summary for the single active chat. The full visible
transcript remains in memory. Inference uses the last committed summary plus the
unsummarized suffix of that transcript. `CompactionState` explicitly records the summary
and the number of transcript messages it replaces, for subsequent persistence work in #9.
This issue does not save or synchronize chats.

## Policy

The session loads an 8192-token context. Before each reply it counts the complete rendered
prompt using the pinned model tokenizer. Above 5888 tokens it attempts compaction, reserving
1536 tokens for summary generation, 512 for the next response, and 256 tokens of headroom.
The summarization prompt itself is separately checked by the session against the exact
context limit. No character-count approximation or hidden truncation is used in production.

The same local Embla model incorporates the previous summary and older turns into a new
summary. The latest two exchanges and the current user message remain verbatim in inference
context. Earlier requirements, facts, preferences, decisions and unresolved questions are
requested in the summary. Summaries can lose details; retaining the visible transcript does
not mean every original detail remains available to the model after compaction.

Only a nonempty summary with a normal stop is accepted. The summary plus recent messages
must fit the exact next-response budget. Output limits, generation errors, cancellation,
and oversized recent messages leave the previous summary and boundary unchanged and show
an error. There is no alternative provider or silent dropping of recent messages.

Summary and response generation share the existing serial session. The composer shows
“Compacting earlier messages…” during summarization. Stop cancels it; New Chat waits for
the engine to stop and then clears transcript, summary and boundary together. Summary
reasoning and internal summary text are not appended as visible assistant replies.

## Validation status

Focused package tests exercise repeated compaction, recent-turn retention, the unchanged
visible transcript, incomplete summaries, failure after a previous successful summary,
and New Chat while summarization is running. Fixture tokenizers/generation are confined
to tests; these do not prove real model summary quality or physical-device behavior.

## Physical-device observation: 2026-11-15

The signed Release build from implementation commit `987b067` was installed in place on
an iPhone 17 Pro running iOS 27.2.1. The downloaded model was retained. Tests used synthetic
messages through Device Hub; no mock model or app launch mode was used.

- First message set the project codename BLUE PENGUIN and release color amber.
- Seven padding batches each contained 650 space-separated digits plus a short instruction
  to acknowledge receipt. Batches were entered in small chunks to avoid flooding remote input.
- Batch 5 visibly triggered “Compacting earlier messages…”, then a normal Received response.
  A follow-up correctly recalled both original facts, now outside the recent-turn suffix.
- Batch 7 triggered compaction again. Stop was requested after observing that status; a
  Stopped row appeared. Subsequent follow-up again recalled both facts. Timing alone does
  not prove whether summary completion or cancellation won that race; deterministic tests
  separately prove cancellation cannot commit a partial summary.
- Settings showed 2752 prompt tokens and 191 generated tokens for the post-cycle recall,
  with the model still stored locally (5.62 GB). These observations are not a broad quality
  benchmark for summaries.
- Cancelled New Chat retained the transcript. Confirmed New Chat cleared it. A fresh
  “What is 2 plus 2? Reply briefly.” produced 4 and reported 22 prompt tokens, demonstrating
  a fresh context rather than the earlier summary. Keyboard capture was returned to off.

An earlier attempt to enter a large prose batch through remote keyboard injection ended
with the app no longer running. No new app-specific crash or Jetsam report was available
from the device when checked, so the cause is unresolved. The subsequent chunked numeric
sequence completed the compaction tests without another exit. Long-input stability remains
tracked under #18; this result does not establish that arbitrary large drafts are safe.

Signed Xcode 27.2 Release device builds and package tests pass. Hosted build/UI checks and
final-head Copilot review remain PR gates. A subsequent review fix filters empty
failed/interrupted assistant placeholders after applying the transcript boundary; focused
retry and boundary-index tests cover that change. The full physical sequence above was
not repeated for that filtering fix.
Local and optional iCloud persistence remain in #9, with iCloud off by default.
