# Context usage and manual compaction (#39)

The composer has a small context ring beside the keyboard control. Tap it for exact
used/capacity values and Compact now. Opening details never starts compaction. A missing
model, pending count or counting error has an explicit state instead of an invented number.

## What the count means

The indicator projects the context for the next message: the stored rolling summary,
retained conversation and current trimmed draft, including its user-message framing even
when the draft is empty. Both counting and generation use the pinned upstream ChatTemplate
and Tokenizer through the same rendering function. Prior reasoning is retained/dropped
according to that template, not counted from the visible text. This is a next-message
projection, not an engine KV-cache or memory-footprint measurement.

A separate serialized tokenizer service reads the verified local tokenizer.json. Counting
while typing does not construct a GPU engine, load model weights, call a network service
or require a successful GPU compilation. Counts debounce draft/stream changes and reject
superseded results. Restore, New Chat, summary changes and foreground activation refresh
them; inactive/background states cancel counting. Production always supplies the real
counter. Internal test construction can inject an explicit counter fixture.

Capacity is 8192 tokens. Details distinguish the 512-token reply reserve, 1536-token summary
reserve and 256-token headroom, explaining the existing automatic threshold of 5888.
The ring rounds the measured fraction to a whole percentage; details retain the exact
integer count. Its fill stops at a full circle if over capacity, while the numeric value
continues to show the measured usage.

## Compact now

Manual compaction uses the existing local model, serial session, summary prompt and
validation rules. It bypasses only the automatic trigger threshold. The latest two
exchanges and current draft stay verbatim; older eligible turns become the rolling summary.
With no eligible prefix, the disabled action explains why. The full visible transcript
and draft remain intact, and no artificial assistant turn is appended.

Stop during summary generation retains the previous committed summary/boundary. Empty,
limited, failed or oversized summaries are rejected. A valid completed manual summary is
saved atomically before being published. Failed saves retain the previous visible and
stored context. Checkpoints and cloud-setting writes cannot queue the old summary behind
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

On 2026-11-15, this test passed on Apple M1 / macOS 26.7.3: manual compaction below the
automatic threshold reduced the exact next-message count from 415 to 105, preserved all
visible turns, persisted the summary and recalled EMBER-42 afterward. The standalone
counter matched the loaded session's tokenizer count. This is real-model host evidence,
not an iPhone performance or simulator-inference claim. Exact reviewed revisions and
hosted results are recorded in the issue/PR before merge.

The isolated iPhone 17 Pro / iOS 27.2 simulator downloaded and verified the real 5.62 GB
model, but model load failed with a Metal compiler XPC connection-interrupted error.
Matching MTLCompilerService crash reports show an LLVM fatal diagnostic/abort. This does
not prove the specific cause. Apple documents [different simulator GPU capabilities](https://developer.apple.com/documentation/metal/developing-metal-apps-that-run-in-simulator).
No alternate model/runtime or simulator response substitute was added. UI/state checks
continue in Simulator; physical validation and the compiler limitation remain recorded in #7.
