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

Real-device compaction and continuation, final app build/UI checks, and final-head Copilot
review are pending. Actual device results will be recorded before issue #8 is closed.
Local and optional iCloud persistence remain in #9, with iCloud off by default.
