# Context usage and manual compaction (#39)

The composer has a small context ring beside the keyboard control. Tap it for exact
used/capacity values and Compact now. Opening details never starts compaction. A missing
model, pending count or counting error has an explicit state instead of an invented number.

## What the count means

The indicator projects the context for the next message: the stored rolling summary,
retained conversation, selected skill, enabled-tool schemas and current trimmed draft,
including its user-message framing even
when the draft is empty. Both counting and generation use the pinned upstream ChatTemplate
and Tokenizer through the same rendering function. Prior reasoning is retained/dropped
according to that template, not counted from the visible text. This is a next-message
projection, not an engine KV-cache or memory-footprint measurement.

A separate serialized tokenizer service reads the verified local tokenizer.json. Counting
while typing does not construct a GPU engine, load model weights, call a network service
or require a successful GPU compilation. Counts debounce draft/stream changes and reject
superseded results. Restore, New Chat, summary changes and foreground activation refresh
them; inactive/background states cancel counting. Production always supplies the real
counter. Internal test construction can inject an explicit counter fixture. Validated last-discovered
tool definitions are saved in device-only settings and remain available for local planning
after backgrounding/restart, without connecting a server or granting a live connection.
Counts use those exact saved definitions; Send reconnects when needed and rechecks the
budget against its discovered catalog. A server can change its definitions between those steps.

Older settings without definitions show an explicit error. **Retry count** now prepares the
enabled servers and counts again; authentication/network failures remain errors. Routine
counting never connects or drops enabled schemas silently. Changing the endpoint or credential
invalidates its saved definitions. Malformed saved metadata is a settings error. During a
tool loop the ring still projects the next user message from the visible transcript; the
session separately checks each actual growing model/tool prompt before generation.

Capacity is 8192 tokens. Details distinguish the 512-token reply reserve, 1536-token summary
reserve and 256-token headroom, explaining the existing automatic threshold of 5888.
The ring rounds the measured fraction to a whole percentage; details retain the exact
integer count. Its fill stops at a full circle if over capacity, while the numeric value
continues to show the measured usage.

## Compact now

Manual compaction uses the existing local model, serial session, summary prompt and
validation rules. It bypasses only the automatic trigger threshold. Both automatic and
manual summary requests quote the historical turns and prior summary as JSON data, separate
from the live task instructions, and use temperature 0 / top-p 1 for summary generation.
Normal conversational sampling is unchanged. The latest two
exchanges and current draft stay verbatim; older eligible turns become the rolling summary.
With saved tool definitions, compaction itself needs no server connection. Older settings
without definitions obtain them during the explicit compaction operation, as Send does,
before budgeting the summary. No MCP tool is invoked merely to summarize the chat.
With no eligible prefix, the disabled action explains why. The full visible transcript
and draft remain intact, and no artificial assistant turn is appended.

Stop during summary generation retains the previous committed summary/boundary. Empty,
limited, failed or oversized summaries are rejected. A valid completed manual summary is
saved atomically before being published. This explicit Saving completed summary phase
no longer offers Stop; it finishes the commit or reports the actual save error. Failed
saves retain the previous visible and stored context. Checkpoints and cloud-setting writes cannot queue the old summary behind
that replacement. The completed summary is saved with the existing local/optional iCloud
snapshot; the indicator does not introduce a new cloud setting or additional uploads.

## Validation

Package tests exercise below-threshold and repeat manual compaction, continuation through
the saved summary, unchanged history/draft, Stop, invalid summaries, failed saves, a draft
edit during a gated summary save, exact projected context arrays, stale count rejection
and background cancellation. Production UI tests exercise the ring/details, unavailable
counting and disabled compaction without weights, preserving the draft. Reset helpers wait
for the real native confirmation and its dismissal rather than retrying an unacknowledged tap.

An opt-in test uses the real pinned runtime and already verified weights on the Mac host:

```sh
EMBLA_REAL_MODEL_ROOT='/path/to/EmblaModels' \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --force-resolved-versions \
  --filter realHostModelManuallyCompactsBelowThresholdAndRecallsTheRetainedFact
```

The root contains the pinned revision subdirectory; this test never downloads or deletes
those model files. It uses synthetic user prompts with real model-generated replies and
summary, writing only its own temporary local chat. The test is disabled by default in CI
and must not be represented as a live pass when skipped.

The real-host test runs on Apple M1 / macOS 26.7.3. It compares an uncompacted
baseline, requires the fact to be absent from the retained verbatim suffix, requires it in
the generated summary, checks reduced exact usage and durable state, and asks for the fact
again. The standalone counter must match the loaded session's tokenizer. Successful
samples and exact reviewed revisions are recorded in the issue/PR before merge. This is
real-model host evidence, not an iPhone performance or simulator-inference claim.

A stricter probe exposed an acknowledgement-only summary when historical instructions
were replayed as live turns; quoted transcript data and deterministic summary sampling
address that failure. A nonce-code probe also produced EMMBER-42 for EMBER-42 in both the
uncompacted and compacted replies even though the summary preserved the exact identifier.
That remains a model-quality limitation. Responses are not rewritten or fuzzy-matched.
The acceptance probe uses the familiar BLUE PENGUIN fact and strict literal checks.

The isolated iPhone 17 Pro / iOS 27.2 simulator downloaded and verified the real 5.62 GB
model, but model load failed with a Metal compiler XPC connection-interrupted error.
Matching MTLCompilerService crash reports show an LLVM fatal diagnostic/abort. This does
not prove the specific cause. Apple documents [different simulator GPU capabilities](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator).
No alternate model/runtime or simulator response substitute was added. UI/state checks
continue in Simulator; physical validation and the compiler limitation remain recorded in #7.

Project chats also count [explicit project memory](projects.md) in the same leading system
prefix used for inference. Notes remain separate from rolling summaries; changing/clearing
notes refreshes the ring. Oversized notes fail clearly without hidden truncation.

## Enabled-server regression (#71)

A regression reproduced the missing-schema failure after pause/restart. Package tests cover
offline counting and manual compaction with saved schemas, unchanged transcript/draft,
credential/endpoint invalidation, rejection of malformed stored metadata and rejection of
remote dispatch without a live connection. The opt-in actual-model test recovers legacy
metadata through Retry, measures an over-threshold synthetic chat with the real tokenizer,
requires automatic compaction, reopens it with no live clients, compacts manually and checks
summary persistence and exact BLUE PENGUIN recall. Results and physical-phone validation
are recorded in #71 and its PR; an opt-in test being present is not a claim it passed.

The #71 real-model regression passed on 2026-11-17 in 85.751 seconds: automatic
compaction reduced 5961 input tokens to 1084, manual compaction worked after reopening
without a live server connection, and the subsequent reply recalled BLUE PENGUIN exactly.
The context-panel simulator regression passed in 22.481 seconds. These are distinct from
physical-device acceptance. The separate physical UI test creates a clearly named
synthetic chat, measures before/after tokens, relaunches and checks recall; it skips
Simulator because it requires the actual model and a signed phone test runner.
Its initial attempt was blocked before launch by missing Xcode account/test-runner
provisioning, not counted as a physical pass. See #71 for subsequent device results.
