# Shared storage layout

When the user enables chat synchronization, the native Files picker grants access to the
`EmblaChat` root in iCloud Drive. Chat storage prepares Chats and Skills; quick actions uses a separate Actions configuration:

```text
EmblaChat/
├── Chats/
│   └── ActiveChat.json
├── Actions/
│   └── actions.json
└── Skills/
    └── skill-name/
        ├── SKILL.md
        ├── scripts/       (optional)
        ├── references/    (optional)
        └── assets/        (optional)
```

`Chats/ActiveChat.json` now contains the format-3 library of all saved transcripts,
rolling summaries, project assignments and explicit project memory. The original filename
is retained for migration from the supported format-1 single-chat and format-2 history
documents. Drafts and selected-chat state remain local. New Chat archives
the previous chat, and the [left sidebar](chat-history.md) reopens saved context. The one
global iCloud switch is optional and off by default; explicit On consent covers all saved
chats and project memory after consent. Existing On installations must confirm that expanded
scope before provider access. Disabled mode never opens the folder provider. Conflict
choices replace a whole
library with explicit confirmation. These operations do not replace, clear or scan Skills.

`Skills` reserves the portable skill library requested in #27. Each copied skill retains its
own directory and relative supporting files. The [Agent Skills specification](https://agentskills.io/specification)
defines `SKILL.md` as YAML frontmatter with required `name` and `description`, followed by
Markdown instructions. The name must match its directory. Supporting scripts, references,
assets and additional files are preserved rather than converted to an Embla-specific format.

The current app creates the Skills directory but does not yet discover, load or execute
skills. Copying a skill does not make its script language, dependencies or tools available
on iOS. #27 must validate compatibility, report unsupported requirements and implement real
tool use. There is no placeholder tool execution or automatic substitute for missing tools.

MCP server connections are a separate capability from the on-disk skill format. #27 tracks
server configuration, authentication, discovery, a cancellable model/tool loop and visible
results/errors against the [MCP specification](https://modelcontextprotocol.io/specification/2026-07-28).
Remote tools can send data over the network even when model inference stays local. That
behavior requires explicit controls and must not be represented as offline inference.

The earlier unmerged storage implementation used `EmblaChat/ActiveChat.json`. Its disposable
validation document is moved intact to `Chats/ActiveChat.json` for the new layout. The app
uses the new path directly; it does not silently choose between two chat locations.

[Quick actions](quick-actions.md) reads Actions/actions.json from the selected cloud root
only when the global preference is durably On. Off uses an on-device Actions directory
visible in Files, excluded from automatic backup. Missing/invalid On configuration never
selects a local substitute. Skills remain reserved; skill cards cannot execute yet.
