# Embla integration investigation

Status: source and metadata investigation completed on 2026-11-14 for #1. No model
weights were downloaded and no iOS build or physical-device inference was performed.

## Selected inputs

- Runtime: [sevren-ai/embla-metal](https://github.com/sevren-ai/embla-metal/tree/1bc69bc355625310b965e19339d255f843023eeb),
  revision `1bc69bc355625310b965e19339d255f843023eeb`.
- Model: [sevren-ai/Embla1-4bit](https://huggingface.co/sevren-ai/Embla1-4bit/tree/4d23eb7de21fc5b55c3051021c7550af1fdce0e8),
  revision `4d23eb7de21fc5b55c3051021c7550af1fdce0e8`.
- Required runtime assets: `config.json`, `model.safetensors`,
  `engram_table.safetensors`, and `tokenizer.json`. Exact sizes and source identifiers
  are recorded in [model-manifest.json](model-manifest.json). LFS object identifiers
  are SHA-256 digests; ordinary Git blob identifiers are not file SHA-256 digests.
- Required assets total 5,624,251,762 bytes (5.624 GB decimal). Storage must also
  accommodate download staging and filesystem overhead. This size is not a RAM budget.
- Retain the model card, tokenizer configuration, generation configuration and Jinja
  template as provenance when implementing the download. The Swift text template is
  the runtime path; the four assets above are `ModelStore.required`.

## Build and hardware contract

[Package.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Package.swift)
declares Swift tools 6.0, iOS 18 and macOS 15. Link the `EmblaMetal` and `EmblaChat`
products using an exact Swift Package Manager revision, retaining the package's copied
`Kernels` and `Web` resource bundles. Do not bundle the Mac CLI or start its HTTP server.

The declared deployment target does not establish the minimum build SDK:
[MetalContext.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaMetal/MetalContext.swift)
references `.apple10` and Metal language `.version4_0`, guarded at runtime by OS 26.
Use an Xcode 26 toolchain with the iOS 26 SDK for the scaffold build and verify iOS 18
compilation there. The README's “Xcode 16 or later” is not sufficient evidence that
Xcode 16 can compile these newer SDK symbols. The runtime selects its existing Metal
3.2 path when neural accelerator support is unavailable; do not override detection.

A physical Metal device is required for inference. Simulator build/launch validates
only scaffold behavior. Model memory is mapped to a shared Metal buffer, while engram
rows are read from disk with `pread`. KV buffers and intermediate allocations grow
with the chosen context. Some allocations force-unwrap and GPU failures call
`fatalError`; the public API does not make every runtime failure recoverable.

The runtime source specifies no mandatory app entitlements. Device deployment needs
an Apple development team, matching bundle identifier, provisioning, and Developer
Mode. Whether increased-memory entitlements are necessary or available must be
measured on the iPhone 17 Pro, not assumed. iCloud capabilities belong to #9, not the
inference runtime. Downloaded weights stay in app-managed local storage, excluded
from iCloud backups; chat data will use the separately designed iCloud store.

## Application API contract

Sources at the pinned revision:
[Chat.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaChat/Chat.swift),
[ChatTemplate.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaChat/ChatTemplate.swift),
[Tokenizer.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaChat/Tokenizer.swift),
and [Engine.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaMetal/Engine.swift).

1. Initialize `ChatModel(directory:context:)` from the verified asset directory on a
   serial worker, away from the main actor. Model loading compiles Metal kernels.
2. Build `[ChatMessage]`, render with `ChatTemplate.render`, then encode with
   `model.tokenizer.encode`. Count actual encoded tokens, including template overhead.
3. Validate nonempty prompt and positive output budget. Enforce
   `prompt.count + maxTokens < model.engine.maxContext` before calling the runtime;
   `model.room(for:)` gives `maxContext - prompt.count - 1`.
4. Construct `ChatModel.Request` with the tokenized prompt, explicit sampling and
   `thinking: true` for the template's open reasoning block. `run(_:emit:)` emits
   `.reasoning(String)` and `.content(String)`, and returns usage/timing/finish reason.
5. Returning false from `emit` requests cancellation. Cancellation is cooperative:
   it cannot interrupt loading, prompt prefill, or work before the first callback.
   Use synchronized cancellation state, await worker completion, and discard stale
   emissions before allowing another run or New Chat. `Task.cancel()` alone is not
   wired into the synchronous runtime. Engine callbacks can already have one extra
   step in flight. Do not reset or unload a running engine concurrently.
6. Serialize all model access. `@unchecked Sendable` is not a thread-safety guarantee.
   `Engine.generate` resets state and processes the supplied full prompt each time;
   the application owns the transcript. `engine.reset()` is available after work stops.
   Release the model only after the worker is idle to relinquish its resources.

Only text conversations are supported; tools and images are outside this template.
Earlier assistant reasoning is excluded by the upstream template. Preserve reasoning
separately from answer text rather than concatenating it into later user messages.

## Context and compaction

The model card advertises 262,144 tokens. This is not an established iPhone memory
capacity. `Engine` defaults to 8,192; the CLI defaults to 32,768. Start the later
inference milestone with an explicit 8,192-token runtime budget, measure it, and
record any change. A smaller tested budget must be an explicit product decision.

There is no summary or auto-compaction API. #8 must generate a summary using this
same model, reserve room for summary generation and subsequent output, and then
re-render summary plus recent verbatim turns. Keep the visible transcript separate.
Preserve old state if summarization fails, and persist summary/context boundaries
through #9. Test repeated compaction and New Chat while work is active.

## Download integration

[ModelStore.swift](https://github.com/sevren-ai/embla-metal/blob/1bc69bc355625310b965e19339d255f843023eeb/Sources/EmblaChat/ModelStore.swift)
provides a synchronous `download` following the remote `main`, a Hugging Face cache
layout, partial-file resume, and SHA-256 checks for newly fetched LFS files. Existing
blobs are accepted by size; `resolve` checks required-file existence only. Progress
is largely written to standard error, not exposed as a structured UI callback.
There is no public cancellation handle or revision argument.

For #3 implement an app downloader against immutable revision URLs and the asset
manifest, with explicit progress/cancellation, verification and readiness. Do not
call the moving-main downloader and describe it as pinned or verified. Missing files,
checksum mismatch, storage errors and provider failures must fail clearly. Never
replace Embla with mock responses or another inference provider.

## Licensing and notices

The pinned runtime LICENSE includes Sevren's MIT notice and Apple's MIT notices for
MLX-derived Metal kernels. An exact copy is in
[third-party/embla-metal-LICENSE](../third-party/embla-metal-LICENSE).
The pinned model card and LICENSE specify MIT, with a Sevren copyright notice;
its exact license is in [third-party/Embla1-4bit-LICENSE](../third-party/Embla1-4bit-LICENSE).
Preserve the applicable copyright and permission notices in app distribution and
alongside any redistributed model assets. These upstream licenses do not select a
license for Embla Chat's own source. No model weights are committed to this repository.

## Validation and remaining evidence

- Inspected the pinned source, model metadata and license files; no upstream changes
  were made. Model checksums are source metadata, not locally verified weight hashes.
- Local toolchain reports Swift 6.2.3; `xcode-select -p` selects CommandLineTools and
  `xcodebuild -version` fails. No Xcode app was found directly under `/Applications`.
- #2 must prove iOS compilation and scaffold launch with a full Xcode installation
  or hosted simulator. #16 must prove a hosted clean build.
- #17 must prove actual iPhone 17 Pro loading, output, cancellation, offline operation,
  memory viability and performance. No iPhone 17 Pro performance is claimed here.
- Upstream README measurements are for M5 Pro and iPhone 18 Pro, not the target phone.
- #9 must verify iCloud provisioning, account behavior and actual persistence.

## Scaffold build finding (2026-11-14)

The first hosted scaffold build exposed an iOS compile blocker in the selected
revision: `ModelStore.swift:18` calls `FileManager.homeDirectoryForCurrentUser`,
which is unavailable on iOS. The package platform declaration is therefore not
proof that the selected `EmblaChat` target builds for iPhone.

Proposed minimal correction: replace that expression with
`URL(fileURLWithPath: NSHomeDirectory())`, retaining the existing cache suffix.
This uses the process sandbox home on iOS. A public fork and new pinned revision
require user authorization; automatic approval review rejected creating the extra
repository without it. No corrected runtime has been published or selected yet.

The latest scaffold check must pass after the dependency fix, followed by a fresh
Copilot review of the final head. #2 remains open until build and launch are proven.
