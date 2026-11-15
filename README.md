# Embla Chat

An iPhone app project for running Embla 1 locally, with one active chat, automatic
context compaction, local chat persistence, and optional iCloud synchronization.
iPad and Mac support are unplanned future work (#10 and #11).

## Current status

Runtime integration and the native SwiftUI scaffold are implemented. Model setup
now includes pinned downloads, SHA-256 verification, progress, cancellation, retry,
and storage deletion. See [model storage](docs/model-storage.md) for behavior and
validation limits. The [inference API](docs/inference-api.md) and conversational screen use
the real pinned Embla adapter. The signed app is installed and launches on iPhone
17 Pro with iOS 27.2.1. Physical testing verified the full model download, real
answers, Stop followed by another request, New Chat, background unloading and
offline model loading/generation. See [device validation](docs/device-validation.md)
for measured results and their limits, and [development](docs/development.md) for build steps.

The chat screen retains one active transcript and supplies prior turns to follow-up
requests. A bottom composer provides Send/Stop; model controls and measurements live in
Settings. The composer follows the supplied ChatGPT reference, with its Send control
inside one rounded card and no separate keyboard Done row. Visual acceptance is tracked
in [chat UI validation](docs/chat-ui-validation.md). Basic Markdown/code rendering, selection,
Copy and output-follow behavior are described in [chat polish](docs/chat-polish.md).
Automatic on-device compaction is
implemented; see [the policy and validation status](docs/context-compaction.md). Local
chat and draft persistence are integrated, including restoration after process exit. Optional,
default-off iCloud Drive synchronization has real iPhone/Mac transfer and restoration evidence; see
[the persistence design and validation status](docs/chat-persistence.md).
The selected cloud root separates `Chats/ActiveChat.json` from portable `Skills` folders;
see [the storage layout](docs/storage-layout.md). Skill loading and MCP execution remain #27.

See [runtime integration](docs/runtime-integration.md) for pinned inputs, APIs,
licensing, build requirements, limitations, and remaining validation.

The [working-version acceptance record](docs/working-version-validation.md) maps Epic 3
requirements to automated and physical evidence, with the remaining release limits.

## App identity

The elm-inspired leaf icon and its generation prompt are preserved in
[branding](docs/branding/README.md), including the sources and uncertainty behind
the name Embla.

## Delivery plan

- [Epic 1: Scaffold and get ready](https://github.com/peterbb148/embla-chat/issues/12)
- [Epic 2: Local inference and minimal UI](https://github.com/peterbb148/embla-chat/issues/13)
- [Epic 3: Working single-chat app](https://github.com/peterbb148/embla-chat/issues/14)
- [Epic 4: Finish the iPhone chat experience](https://github.com/peterbb148/embla-chat/issues/15)
- [Epic 5: Skills, MCP tools, and model upgrades](https://github.com/peterbb148/embla-chat/issues/38)

Tasks are tracked in GitHub Issues. Work is delivered one issue and PR at a time,
with Copilot review of the final commit and passing checks before merge.
