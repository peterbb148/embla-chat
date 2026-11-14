# Embla Chat

An iPhone app project for running Embla 1 locally, with one active chat, automatic
context compaction, and iCloud chat persistence. iPad and Mac support are planned later.

## Current status

Runtime integration and the native SwiftUI scaffold are implemented. Model setup
now includes pinned downloads, SHA-256 verification, progress, cancellation, retry,
and storage deletion. See [model storage](docs/model-storage.md) for behavior and
validation limits. Inference and chat are not implemented yet, and physical iPhone
inference remains unverified. See [development](docs/development.md) for build steps.

See [runtime integration](docs/runtime-integration.md) for pinned inputs, APIs,
licensing, build requirements, limitations, and remaining validation.

## Delivery plan

- [Epic 1: Scaffold and get ready](https://github.com/peterbb148/embla-chat/issues/12)
- [Epic 2: Local inference and minimal UI](https://github.com/peterbb148/embla-chat/issues/13)
- [Epic 3: Working single-chat app](https://github.com/peterbb148/embla-chat/issues/14)
- [Epic 4: Polish and platform expansion](https://github.com/peterbb148/embla-chat/issues/15)

Tasks are tracked in GitHub Issues. Work is delivered one issue and PR at a time,
with Copilot review of the final commit and passing checks before merge.
