# Working single-chat version acceptance (#6)

## Scope

Epic 3 integrates the accepted conversational screen (#25), single-chat flow (#5),
automatic compaction (#8) and durable local/optional iCloud persistence (#9).
This audit covers merged implementation `a53e20272bf66f6e4f31dc7203b32dc790e4e692`.
It changes documentation rather than application behavior or validation infrastructure.

## Acceptance matrix

| Requirement | Automated evidence | Physical evidence and limits |
| --- | --- | --- |
| Model readiness, download, verification and errors | Model storage/session tests cover integrity, cancellation, retries and lifecycle; UI tests require a verified model before Send | [Device validation](device-validation.md) records the full download, real model loading, measurements and offline answers |
| Conversational streaming, follow-ups and Stop | `LocalInferenceModelTests` checks actual context arrays, partial/limited/error states, worker draining and another request after Stop | [Accepted chat UI](chat-ui-validation.md) records real multi-turn replies, software keyboard and user visual acceptance; earlier device checks cover Stop/retry |
| Confirmed/cancelled New Chat | Controller and UI tests cover cancellation, durable reset, a locked composer until completion, failed-save preservation and stale-write exclusion | Final persistence build: cancellation retained the chat; confirmation cleared transcript/summary and synchronized an exact empty snapshot with a new identity |
| Automatic compaction with retained visible history | Core budget tests and controller tests cover repeated compaction, oversized inputs, empty/limited/failed summaries, cancellation and preservation of the last committed summary | [Compaction validation](context-compaction.md) records two observed cycles and real fact recall. The Stop race is explicitly qualified; arbitrary large-input stability remains #18 |
| Reopen a local-only chat, summary and draft without restarting generation | Real archive round trips and controller restoration tests include stored summaries, interrupted responses, drafts and corrupt storage. Simulator tests cover draft restoration | [Persistence evidence](chat-persistence.md) records Off/restart with restored summary/draft and real recall on an earlier build. The final reviewed build separately verified durable Off/restart and an empty local chat |
| Optional, default-off iCloud with honest status and recoverable errors | Consent/disable tests include gated real saves, delayed reads/writes, conflicts, retry, failed metadata, stale choices and foreground/background races; coordinated-file tests reject stale replacements | Actual cloud fixture restoration, real model recall and upload, divergent-copy selection, reset and saved Off/reopen are recorded with exact tested commits. Synthetic fixtures are labelled; they are not model output |
| Retain model independently from chat operations | Controller tests cover New Chat without model deletion and model deletion despite corrupt chat storage | The 5.62 GB model remained stored after final reset/restart checks |

Test implementations are in `Tests/EmblaCoreTests`, `Tests/EmblaPresentationTests` and
`EmblaChatUITests/LaunchTests.swift`. Explicit fixture backends exist only in tests;
the application's public runtime path uses the pinned Embla adapter.

## Reproducible checks

The existing `scripts/check.sh` entry point enforces full Xcode 26.2, locked package
resolution, package tests, unsigned generic-iPhone Release build and five UI tests on
an isolated iPhone 17 Pro simulator. It cleans up that simulator and retains logs/results.
The provider check fetches only the pinned small config file; CI does not download weights
or claim real inference or iCloud transfer.

The final implementation head `a98ff75d87d59c104ea3b7a73b18d28e1a789028` passed
[CI run 43723035733](https://github.com/peterbb148/embla-chat/actions/runs/43723035733):
84 package tests (including parameterized cases), Release build and five UI tests.
Local package tests and Xcode 27.2 simulator/device builds also passed. That head received
Copilot review with no open findings and no unresolved threads before PR #31 merged.
The documentation audit receives its own final-head CI and review before merging.

## Remaining work

Epic 3 delivers a working version, not final release acceptance:

- #18: Markdown/code rendering, Copy/selection, scrolling and storage-control
  polish and investigation of the earlier large remotely injected input exit.
- #7: final release/device matrix, including physical OS-generated NSFileVersion conflicts
  and forced account, permission and transfer failures. Those OS scenarios were not forced;
  fixture success is not physical proof. This audit does not authorize account sign-out,
  destructive cloud resets or expanded personal-data access.
- Epic 4 also contains #33 chat history/sidebar, #34 Projects/memory, #37 configurable
  quick actions. Subsequent #39 work adds [context usage/manual compaction](context-usage.md);
  it was outside the original Epic 3 acceptance checkpoint.
- Epic 5 contains #27 portable skills/MCP execution and #35 model upgrades.
- #10 iPad, #11 Mac, #32 Developer Program capabilities/distribution and #36 additional
  model families are unplanned. The current model is an immutable verified revision;
  it has no in-app update or model-selection workflow.

The initial cloud toggle applies to all chats and defaults off. Future per-chat privacy
must also cover derived project memory. The current app has one active chat, creates
`EmblaChat/Chats` and `EmblaChat/Skills` in the selected cloud root, and does not load
skills or execute tools. `EmblaChat/Actions` remains a future configuration path in #37.

## History extension (#33)

The [history/sidebar](chat-history.md) extends the original single-chat checkpoint. It preserves
separate transcripts, summaries and drafts on navigation; New Chat is no longer destructive.
The global cloud option now covers the complete library, with drafts remaining local. The
physical single-chat evidence above does not validate this new multi-chat document format.

The user explicitly deferred new real multi-chat iCloud provider/failure checks to unplanned
#45. Those checks no longer block Epic 4; existing physical evidence remains commit-specific.
