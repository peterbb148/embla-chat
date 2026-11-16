# Skills and MCP tools

Embla keeps model inference on-device. A user-selected skill supplies instructions to the
local model; registered, enabled MCP tools can send arguments to a configured server.
These are distinct permissions. Copying a skill never installs software, starts a server or
authorizes a connection.

## Portable skills

Copy a complete standard skill folder into `Skills/<skill-name>/SKILL.md`. With the global
iCloud preference Off this is the app's on-device Documents/Skills folder, visible in Files.
With it On, Skills is read only from the durably authorized EmblaChat root. Unavailable
cloud permission is an error, never a reason to use on-device files instead. Chat sync and
New Chat do not modify skills.

The [Agent Skills specification](https://agentskills.io/specification) defines YAML
frontmatter with required `name` and `description` and Markdown instructions. Embla uses
the pinned MIT-licensed Yams parser, including folded/multiline YAML values. Names must
match their folders. Optional compatibility, declared tools and metadata are preserved;
compatibility requirements are shown for the user to assess. Invalid entries show their
actual error. Metadata/tool declarations do not grant permissions.

Use the sparkle button beside the composer to reload, inspect and explicitly select a
skill. Its name remains visible in the composer. Selection is cleared when changing chats,
reloading the skill source or leaving the active app. Skill actions in `Actions/actions.json`
select a named skill and optionally fill a draft, with the same replacement confirmation
as prompt actions. Nothing submits automatically.

Embla reads metadata for discovery and adds the selected instructions to the exact counted
system context. It does not put every skill into the model's context. A selected skill can
request `skill/read_skill_file` for a relative UTF-8 supporting file. Selecting the skill authorizes that read; the actual returned text enters the tool loop. The selected SKILL.md fingerprint
is rechecked before use and resource reads. Scripts, shell commands, arbitrary filesystem
access, binary/image resources and installing dependencies are unsupported. The app does
not claim those capabilities because files happen to be present. Each skill/resource is
limited to 64 KiB, metadata to 16 KiB and the top-level library to 256 entries; oversized
input fails rather than being silently truncated. Symbolic links and path traversal are
rejected. The normal exact tokenizer/context limit still applies. Yams 6.2.2 is locked to its verified commit in
both lockfiles; its own and included LibYAML notices are bundled in the shared resources.

See [the copied-skill example](../examples/skills/concise-writing/SKILL.md).

## MCP configuration and network boundary

Settings → MCP servers configures explicit endpoints and optional bearer tokens. Save a
server, connect/discover, then enable the desired tools. Enabled registrations reconnect on
Send after backgrounding/restart; discovery and calls do not run merely at app launch. No server or tool is enabled by
default. The endpoint must use HTTPS; loopback HTTP is allowed for local developer tests.
Redirects are rejected, and the client has no cookie jar or shared credential store.
Credentials/query strings in endpoints are not supported. Name, endpoint and selected
tool names are stored in excluded-from-backup device settings, separately from chat and
skill files. Tokens use non-synchronizing, When-Unlocked-This-Device-Only Keychain items;
the app does not add credentials to model prompts or portable documents. Credentials are
bound to the exact endpoint as well as the registration ID, preventing a failed settings
save from supplying a replacement endpoint’s token to the previous destination. Removing
a registration clears its endpoint-specific Keychain entries.

The first implementation explicitly supports
[MCP 2026-07-28 Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http),
with per-request version/capability metadata and mirrored headers, `server/discover`, paged
`tools/list`, `tools/call`, JSON responses and request-scoped SSE. Parameter-header schema
annotations are validated and encoded according to that revision. Invalid annotated tools
are excluded with visible warnings. Saved enabled names remain visible and can be disabled
even if discovery fails or a server no longer lists them. A response is bounded to 128 KiB; discovery is limited
to 64 tools and 16 cursor pages. Unsupported result types/capabilities, malformed responses,
HTTP/protocol errors and actual tool errors fail clearly. SSE rejects malformed UTF-8
instead of inserting replacement characters. JSON-RPC failures retain their
code, message and data, including valid protocol errors carried by non-200 HTTP responses. Corrupt saved settings are not
replaced by an empty tool-free configuration or overwritten automatically.

The official Swift SDK currently documents an older protocol revision; it is not assumed
to implement the changed 2026 stateless protocol. This client implements the explicitly
scoped current HTTP subset. There is no automatic switch to an older protocol or provider.
Older-only MCP servers, legacy SSE transports, local subprocess launch, browser OAuth,
sampling, elicitation, subscriptions and MCP Apps are unsupported. OAuth-only endpoints
show an authorization error; a pasted bearer token must be obtained by the user through
the server's supported process. It is not a substitute browser OAuth implementation.

Each model-generated request is checked against the currently registered/enabled catalog.
Enabling a registered tool grants standing authorization for automatic calls; there is no
per-call approval dialog. Selecting a skill similarly authorizes supporting-file reads
inside it. Settings describe this policy and the endpoint. Exact argument/destination
snapshots are recorded before execution, and a changed configuration invalidates dispatch.
Only arguments and connection/protocol metadata go to the server automatically, not the
full transcript. Arguments can nevertheless contain chat-derived personal information.
Server descriptions/annotations/results are untrusted; they cannot register or enable other tools.

Calls and returned results/errors are retained in the saved chat and follow the existing
global iCloud consent. Local inference plus a remote tool is not fully offline operation.
Stop/inactivity cancels pending model/network work. Cancelling a
network request cannot undo effects that already occurred on the server. No failed result
is replaced with invented data.

## Model contract and evidence

The checkpoint's published [chat template](https://huggingface.co/sevren-ai/Embla1-4bit/blob/4d23eb7de21fc5b55c3051021c7550af1fdce0e8/chat_template.jinja)
provides a trained function/parameter format. The pinned Swift runtime only exposes text
roles, so Embla adapts that format in the leading system context and wraps actual results
in `tool_response` user turns. It does not claim the upstream Swift API has native tool roles.
Tool-enabled turns buffer output until the complete call or answer validates; ordinary
tool-free chat retains streaming. A model request looks like:

```text
<tool_call>
<function=mcp_example__get_current_time>
<parameter=timezone>
Europe/Copenhagen
</parameter>
</function>
</tool_call>
```

JSON integer arguments/results retain signed/unsigned 64-bit values exactly, including IDs
beyond the exact Double range. Out-of-range integers fail rather than round; fractional
values use Foundation Decimal’s supported precision. MCP integer parameter headers retain
the specification’s narrower safe-integer bound.

Function names map exactly to a captured server/tool catalog; they are not inferred from
prose. String parameters use the checkpoint's plain-text convention; other parameter values
must be JSON. Plain final answers need no JSON envelope. Unknown/multiple/incomplete calls,
duplicate/missing required parameters and output-limited responses fail without dispatch.
There is no repair, guessed identifier, retry-until-execution or substituted tool result.
The loop uses greedy sampling, at most four registered-tool executions and five model passes.
Exact token counting includes skill instructions, schemas, project memory, rolling summary
and the growing exchange. Oversized context fails without dropping tool results.

Initial real-host experiments used the unchanged pinned Embla weights/runtime on Apple M1.
A custom JSON protocol produced both successes and malformed requests/final-answer shapes;
several full-app probes failed before approval or dispatch. Inspection of the checkpoint's
published template established the intended function format, replacing that experiment.
Those rejected probes are not treated as successful native-format reliability evidence.

The application's actual orchestration/registration/persistence path passed three English/Danish
Time.Now call/answer cases in 32.136 s under the final automatic-call policy. Each retained
enabled registration but cleared live connections first, proving automatic reconnect on Send.
There was no per-call confirmation. Each saved the exact returned timestamp and the real
model used it in its answer. All three cases passed again after the credential/precision
review fixes in 28.327 s, including returned `2026-11-16T07:50:52.033273+01:00`.
An independent selected-skill test passed in 15.927 s: the same greeting prompt produced
`Hello! How can I help you today?` without the skill and an answer beginning `SKILL ACTIVE`
with the copied standard skill. These are complete functional test durations, not iPhone
performance measurements or broad reliability guarantees. Settings generation metrics describe
the last model pass, not total network/tool-loop duration.

The [Time.Now provider](https://time.now/developer/mcp) documents the public read-only,
no-auth endpoint `https://time.now/mcp`; the live probe advertised version 2026-07-28.
It is a user-added example, not an automatic connection or an Embla-owned service.
The official hosted MCP reference endpoint instead returned an OAuth 401; no sign-in or
credential was created. Provider availability and data can change.

Package tests distinguish control-flow fixtures and the synthetic loopback HTTP/SSE server
from opt-in actual-model/public-server tests. The current suite reports 126 presentation
and 29 core tests; five actual-model cases are opt-in and skipped by default. All ten
production UI tests passed on the existing iPhone 17 Pro/iOS 27.2 simulator, including
skill access and no-network/no-token server registration/removal. No new simulator was
created. App-only UI screenshots are retained in the result bundle. Final hosted checks,
review and merge evidence are recorded in [#27](https://github.com/peterbb148/embla-chat/issues/27)
before delivery is declared. New-format real iCloud validation remains the separately
deferred #45, not a successful test implied by this implementation.
