# Epic 4 delivery acceptance (#7)

## Delivered scope

Epic 4 builds on the earlier physically tested single-chat app. It adds Markdown/code and
scrolling polish, exact context usage with manual compaction, saved-chat history, Projects
with explicitly saved memory, and configurable prompt actions. The accepted ChatGPT-style
layout is retained. Accessibility work is limited to ordinary native controls and labels,
as requested; no dedicated accessibility audit is claimed.

The latest Epic 4 application has been tested on the existing iPhone 17 Pro simulator
without creating another local simulator. Real inference checks use the pinned model on
an Apple M1 Mac because the attempted simulator model load failed in the Metal compiler.
At the final-audit scout, CoreDevice reported the paired physical iPhone 17 Pro disconnected;
the existing iPhone 17 Pro simulator was available. Earlier physical-iPhone evidence is retained
at its tested revisions; it is not proof that the latest history/Projects/Actions build has been installed or run on the phone.

## Acceptance matrix

| Delivery | Evidence | Boundary |
| --- | --- | --- |
| Markdown/code, exact Copy, selection and scrolling (#18, PR #41) | Merged `8ac4eb9`; production UI and presentation checks; [polish record](chat-polish.md) | No broad accessibility audit or arbitrary-input stability guarantee |
| Exact context ring and Compact now (#39, PR #43) | Merged `e4c757d`; exact tokenizer checks; real-host BLUE PENGUIN summary/continuation reduced usage from 416 to 106 tokens; [context record](context-usage.md) | 37.15 s is whole host-test duration, not iPhone performance; nonce spelling failure also occurred without compaction |
| History/sidebar (#33, PR #44) | Merged `450d49f`; production restart/draft UI; real-host independent BLUE PENGUIN/RED FOX recall across switch/restart in 40.23 s; [history record](chat-history.md) | New multi-chat cloud format has not had real-provider transfer validation |
| Projects and explicit memory (#34, PR #46) | Merged `4e4638b`; real-host same-project sharing, other-project isolation, edit/restart and clear in 38.55 s; actual editor/Cancel/Save/source link inspected; [Projects record](projects.md) | UI-only source fixture was labelled synthetic, not model output; no automatic extraction of memory |
| Paused renewed cloud consent | Existing iPhone 17 Pro/iOS 27.2 production app: old On/scope-0 local fixture showed paused status, disabled Sync now and enabled Choose iCloud folder. Tapping opened the renewed-consent dialog; Cancel kept it paused. Switching Off visibly restored Off. | No folder was selected, no provider constructed and no cloud transfer performed; original chats/drafts retained |
| Quick actions (#37) | [Configuration and validation](quick-actions.md); package file/consent/race tests; nine production UI tests; app-only screenshots of cards, composer and replacement alert; actual compiled Files declarations checked | Prompt actions fill editable drafts and never submit automatically. Skills/MCP execution remains #27; real cloud configuration transfer remains #45 |
| Model download, real iPhone inference, Stop/reuse and offline operation | [Physical device record](device-validation.md) names source `bfa25a4`, iPhone 17 Pro/iOS 27.2.1 and measured load/decode/memory observations | Historical minimal-screen evidence; not a benchmark for the latest Epic 4 features |
| Physical compaction and single-chat cloud persistence | [Compaction](context-compaction.md), [persistence](chat-persistence.md) and [Epic 3 checkpoint](working-version-validation.md) retain exact tested revisions and outcomes | These predate the new library format and do not validate multi-chat/project-memory provider behavior |
| Repository readiness (#48, PR #49) | Merged `f01fadd`; MIT recognized by GitHub, valid CODEOWNERS, active protected-main rules, full-query Swift/Actions/Python CodeQL, dependency and strict history scans; 19 helper regressions; fresh owner-login native-alert attestation at reviewed `b47ae1b` before merge | The native check is a maintainer snapshot, not continuous monitoring or native scan-completion proof; see [security policy](repository-security.md) |

## Reproduction and evidence interpretation

[Development](development.md) documents locked dependency builds and local commands that
reuse an existing simulator ID. Hosted `scripts/check.sh` uses a disposable runner, runs
package tests, builds an unsigned generic-iPhone Release app, asserts both actual compiled
Files-sharing keys, and runs all nine production UI tests. It removes its own isolated
simulator on exit. Hosted checks do not download model weights or run real inference. Their readiness UI
scenario requires an unconfigured model, local cloud saving Off and starter quick actions;
reused local simulators need those explicit prerequisites without unauthorized data deletion.

The delivered application package suite reports 133 tests: 111 presentation and 22 core.
Live-model tests are opt-in; default execution is not a live inference pass. The three
explicit real-host observations above were run separately with verified pinned weights,
not concurrently. Their timings measure complete functional test runs, not model throughput.
The runtime remains `0c8caaa3616372482d047fa9e953ea656cb34588`; the model remains
`sevren-ai/Embla1-4bit` revision `4d23eb7de21fc5b55c3051021c7550af1fdce0e8`.
Both lockfiles and the model manifest retain these pins. [Runtime integration](runtime-integration.md)
and bundled `third-party` notices document licenses and provenance.

The earlier simulator model-load attempt failed with a Metal compiler XPC/LLVM fatal
error. There is no alternate backend or fake successful response. Upstream fatal GPU
failures cannot all be caught as Swift errors. Stop is cooperative and waits for work to
drain; model load and prompt prefill are not immediately interruptible. Summary quality
and model output can be imperfect, and a full visible transcript remains available.

## Privacy and deferred work

Chats, drafts, summaries and explicit memory are saved locally. Optional iCloud is Off by
default. The single global switch covers saved chats and project memory after durable,
explicit consent; existing On installations pause for the expanded scope. Drafts, model
weights and folder grants remain local. Turning Off stops new app operations and retains
existing cloud files; iCloud Drive may already have queued a transfer. Cloud failures stay
visible; no failure-driven switch to another data source occurs. When On, Actions use the selected cloud folder only after the same durable authorization;
Off uses local Files. Pending or failed cloud authorization does not select a local substitute.

The user explicitly deferred new-format personal-iCloud transfer and OS/account/permission
failure checks to [#45](https://github.com/peterbb148/embla-chat/issues/45). They are outside
Epic 4 and are not relabelled as successful tests. The simulator's iCloud Drive stays off.
Latest-build physical installation and performance measurements have not been repeated;
the physical records above remain scoped to their source revisions.

Epic 5 contains [#27](https://github.com/peterbb148/embla-chat/issues/27) Skills/MCP and
[#35](https://github.com/peterbb148/embla-chat/issues/35) model upgrades. iPad #10, Mac #11,
Developer Program/distribution #32, other model families #36, per-chat cloud controls #42
and provider validation #45 remain unplanned. Model download/retry/deletion is implemented;
in-app model upgrades and model selection are not.

## Repository delivery evidence

PR #49 merged the open-source setup at `f01fadd7e6c9241fc5ffa47bb867bc2acd4b585d`.
Its reviewed head `b47ae1b01f854dea658cfa698cd91d6f296c4b43` passed
[iPhone CI 43769638553](https://github.com/peterbb148/embla-chat/actions/runs/43769638553),
[security CI 43769638576](https://github.com/peterbb148/embla-chat/actions/runs/43769638576) and
[full-query CodeQL/inventory 43769638714](https://github.com/peterbb148/embla-chat/actions/runs/43769638714).
All eight required statuses, zero open code-review findings and the exact head were checked
before the SHA-pinned merge. The actual maintainer tool published the native-alert status
using the existing gh login; no new credential was copied to CI. Post-merge results and
fresh inventories are recorded in [#48](https://github.com/peterbb148/embla-chat/issues/48).
The documentation audit and final-main results are recorded in
[#7](https://github.com/peterbb148/embla-chat/issues/7).

The native secret scan-history endpoint returns HTTP 404 for this public personal repository
while secret scanning and push protection are enabled. The current inventory is readable;
it cannot prove per-head scan completion or prevent later-published findings. The owner
chose a required fresh maintainer attestation. It complements the synchronous full-history
scanner and must be repeated immediately before each merge, then checked again afterward.
No elapsed-time heuristic or unavailable API is treated as completed scanning.
