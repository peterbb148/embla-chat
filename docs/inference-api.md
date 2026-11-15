# Local inference API

`EmblaRuntime.makeSession()` creates the production `EmblaCore.InferenceSession`.
The production adapter always uses the pinned Embla Metal runtime. There is no
HTTP listener, remote inference provider, or placeholder response path.

## Loading and generating

```swift
import EmblaCore
import EmblaRuntime

let manifest = try ModelManifest.bundled()
let repository = ModelRepository(root: try ModelRepository.defaultRoot(), manifest: manifest)
let session = EmblaRuntime.makeSession()
try await session.load(from: repository, contextSize: 8192)
let run = try await session.generate(
    messages: [ConversationMessage(role: .user, content: "What is the capital of Denmark?")],
    options: GenerationOptions(maxTokens: 512)
)
do {
    for try await event in run.events {
        // Render reasoning and answer separately; finished carries token and timing metrics.
        // Dispatch UI updates to the main actor.
    }
} catch {
    // Report cancellation separately from loading or generation errors.
}
await run.waitUntilFinished()
try await session.unload()
```

A caller owns the active `GenerationRun`. It must consume the stream or cancel it,
then await `waitUntilFinished()` before treating the engine as stopped. Loading,
tokenization, generation, reset and unloading run serially on the session actor.
The session uses a dedicated serial executor for blocking Metal work, avoiding
both the main actor and starvation of Swift concurrency cooperative workers. The stream emits
reasoning text, answer text, then completion metrics; cancellation throws rather
than pretending the answer completed.

## Cancellation, reset and lifecycle

Call `run.cancel()` from the UI to request a stop without waiting for the session
actor, which may be busy inside synchronous GPU work. Cancelling the stream consumer
also requests cancellation. Wait for the run's worker to finish before starting
another request, resetting, unloading, or allowing model deletion. Always await
completion even if stream consumption throws. A cancelled run resets the engine
and leaves the loaded session ready for another request.

Cancellation is cooperative at the upstream emitted-text callback. It cannot abort
model initialization, shader compilation or prompt prefill midway. The upstream
engine drains submitted GPU commands before returning; the application must display
that it is stopping until the worker finishes. Cancelling a loading Task is checked
before and after the synchronous constructor, releasing the model if cancelled.

The shared chat controller cancels, waits, and unloads on background transition;
unloads before model storage operations; discards stale events; and applies the
same cancellation/wait sequence for New Chat. Presentation tests verify this
sequencing with fixtures; physical observations are recorded in
[device validation](device-validation.md). No background inference
is supported. A thrown generation failure unloads the failed backend and requires
an explicit reload before retrying. A genuine backend error remains an error even
if a cancellation request races with it; cancellation never hides diagnostics or
marks a failed backend reusable.

## Conversation and context contract

The shared controller keeps a chronological `messages` transcript and supplies all
user turns and nonempty actual assistant text/reasoning on every Send. Cancelled and
limited responses keep their explicit UI state and their real partial content. New Chat
waits for active work to drain, saves the previous transcript/summary/draft in history,
and resets inference state. Selecting an earlier chat restores its own context without
starting generation.

The application supplies the conversation. The adapter uses upstream ChatTemplate
and Tokenizer without heuristic substitutes. Earlier assistant reasoning is handled
by that template. `tokenCount(messages:)` counts the complete rendered prompt, not
characters. `generate` checks that the prompt and requested output fit strictly
inside the runtime context before entering Engine.generate and its preconditions.
Invalid settings and empty user input fail clearly.

The initial context is explicitly 8,192 tokens, matching the investigated starting
budget, with 512 output tokens, temperature 0.6 and top-p 0.95 by default. These are
configuration defaults, not evidence of iPhone memory viability or performance.
The UI must show a length-limited result honestly if the budget expires during
reasoning. The presentation layer now orchestrates local compaction through this API;
see [context compaction](context-compaction.md) for policy and device evidence.

The upstream engine reconstructs inference state from the full prompt on each run.
`reset()` clears runtime state only after a run completes. For context replacement,
provide the new summary/recent-message array on the next call; the visible transcript
and persistence are owned by the application (#8/#9).

## Errors and evidence boundary

Storage validation and thrown runtime-load/template errors are propagated with
upstream diagnostic descriptions. Some upstream Metal allocation and GPU failures
use force unwraps, preconditions or fatalError and can terminate the process; this
adapter cannot catch those as Swift errors. Device validation must record crashes
and memory failures rather than report successful inference. No alternate backend
is selected after failure.

The runtime adapter compiles locally with Command Line Tools, including the actual
Embla dependencies. Core lifecycle tests use an explicit test backend to exercise
streaming, cancellation, serialization, budgets, reset, unload, and reload after a
thrown failure. These tests do not run the model. Hosted checks build the adapter
for iOS. Actual output, measured memory and offline operation were observed in #17;
see [device validation](device-validation.md) for the tested implementation and limits.
The conversational UI work in #25 requires its own context/keyboard observations.
