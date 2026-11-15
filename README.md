<p align="center">
  <img src="docs/branding/embla-leaf-source.png" alt="Embla Chat leaf icon" width="96">
</p>

# Embla Chat

Local-first AI chat for iPhone, powered by [Embla](https://github.com/sevren-ai/embla-metal)
and Apple's Metal framework.

Run conversations on your device, organize them into Projects, and choose whether to sync
saved chats through iCloud Drive. Model inference runs locally after the model is downloaded.

## Features

- A conversational interface with streaming responses, Markdown, code blocks and copying.
- Saved chat history, a sidebar and separate drafts for each conversation.
- Projects with editable memory that you explicitly save from a chat.
- Automatic context compaction, a usage indicator and manual compaction controls.
- Configurable quick actions that fill editable prompts.
- Model download, integrity verification and storage management.
- Optional iCloud Drive synchronization, off by default.

## Getting started

You need a Mac with full Xcode to build the app. See the [development guide](docs/development.md)
for supported toolchains, locked dependencies and simulator testing, and the
[device guide](docs/device-validation.md#install) for signing and installation.

```sh
git clone https://github.com/peterbb148/embla-chat.git
cd embla-chat
open EmblaChat.xcodeproj
```

Select the **EmblaChat** scheme and your destination in Xcode. For local inference, build
for a supported physical iPhone and download the model from the app's Settings. The
[model storage guide](docs/model-storage.md) explains download size, verification and retry.
Simulator UI checks do not establish model-inference support; see the linked validation
records before relying on a particular device or configuration.

## Privacy and storage

Conversations and drafts are saved locally. Enabling iCloud is an explicit choice and
applies to saved chats and project memory; drafts and model files stay on the device.
Turning synchronization off keeps existing cloud files. Project memory is saved explicitly
rather than extracted automatically from your chats.

See [persistence](docs/chat-persistence.md) and [storage layout](docs/storage-layout.md) for
consent, file formats, conflicts and configuration folders. Quick actions are documented
[here](docs/quick-actions.md).

## Architecture and documentation

The app uses SwiftUI, shared Swift packages for inference and presentation, and a pinned
Embla Metal runtime. There is no remote inference service in the application path.

- [Development and testing](docs/development.md)
- [Inference API](docs/inference-api.md) and [runtime integration](docs/runtime-integration.md)
- [Context management](docs/context-compaction.md) and [context usage](docs/context-usage.md)
- [Chat history](docs/chat-history.md) and [Projects](docs/projects.md)
- [Validation records](docs/validation.md)
- [Branding and the name Embla](docs/branding/README.md)

Tested revisions, platform limitations and measurements belong in the validation records.
Planned work and bug reports are tracked in [GitHub Issues](https://github.com/peterbb148/embla-chat/issues).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development and pull-request workflow.
Report vulnerabilities using the guidance in [SECURITY.md](SECURITY.md).

## License

Embla Chat's original code is licensed under the [MIT License](LICENSE). Upstream runtime
and model licenses remain separate; notices are retained in [third-party](third-party).
Model weights are downloaded separately and are not bundled in this repository.
