# Contributing

Use [GitHub Issues](https://github.com/peterbb148/embla-chat/issues) for bugs and proposed
features. Describe the behavior, reproduction steps and relevant device/toolchain; never
include private chats, credentials, signing material or downloaded model files.

Read the [development guide](docs/development.md) before changing the app. Work in a scoped
issue branch, keep dependency revisions locked, and include documentation with meaningful
behavior changes. Prefer small changes that follow existing SwiftUI/package boundaries.
Run the relevant package/build/UI checks; distinguish fixtures and simulator UI results
from real model, physical-device and iCloud-provider evidence.

Open a pull request linking its issue and describing behavior and validation. Required
build/security checks and resolved review conversations are merge prerequisites. Findings
must be fixed and the final commit re-reviewed; do not suppress vulnerabilities to make a
check pass. External contributions require approval from the code owner, **@peterbb148**.
Internal work by Peter and the coding agent follows the same checks and final-head Copilot
review process, without an impossible self-approval requirement.

Contributions to original project code are under the [MIT License](LICENSE). Keep upstream
license notices and attribution intact. See [SECURITY.md](SECURITY.md) for private reporting
and the repository's security policy.
