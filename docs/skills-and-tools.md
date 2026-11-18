# Skills and MCP tools

Open **Settings → MCP Servers** to manage server connections. Each server with enabled
tools shows its enabled method count in parentheses, for example **Time.Now (3)**.
Servers with no enabled methods show their name without a count.
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

Open **Settings → Manage skills** to reload, inspect and explicitly select a skill.
Skill management is separate from MCP Servers; the composer does not open the manager. Its name remains visible in the composer. Selection is a persisted global preference;
changing chats retains it, and foreground/source reload validates the saved selection again.
A missing selected skill fails visibly. See [shared settings](settings-sync.md). Skill actions in `Actions/actions.json`
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
rejected, including a symlinked top-level Skills storage folder in either source. Reads and
library enumeration use a pinned directory descriptor; each child opens with openat and
O_NOFOLLOW. Replacing a checked folder with a symlink cannot redirect the read. File
coordination is retained for cloud materialization, without reopening the absolute path.
The normal exact tokenizer/context limit still applies. Yams 6.2.2 is locked to its verified commit in
both lockfiles; its own and included LibYAML notices are bundled in the shared resources.

See [the copied-skill example](../examples/skills/concise-writing/SKILL.md).

## Finding and adding servers

Open **Settings → MCP Servers → Browse registry**. Search server names, inspect a listing's
publisher name, catalog version and connection address, then choose **Add server**. The
registration form fills its name and endpoint; provide a bearer token if required and save.
Successful MCP discovery enables all its tools. All enabled servers remain available to
every chat; the proposed per-chat composer picker is deferred in #65.

The browser reads the [official MCP Registry API](https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/official-registry-api.md)
anonymously, using active/latest records and opaque pagination cursors. **Load more**
keeps the same name search and version filter. Nonempty searches need at least three
Unicode characters after trimming; shorter input shows a hint without requesting the API.
Search text goes to that registry; chats,
model prompts and saved server credentials do not. Closing the browser cancels its request.
A failed request displays its actual error and an explicit Retry action.

Only HTTPS Streamable HTTP endpoints compatible with the current client are shown.
Local packages/processes, legacy transports, URL variables, query credentials and custom
headers are excluded. Standard bearer-token configuration is supported, including listings
that declare it required. A listing can still require unsupported browser OAuth or be
unavailable; actual connection/authentication errors remain visible. The catalog's
[namespace verification](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/remote-servers.mdx)
does not prove ownership of its remote URL. Records keep their own name/version identity,
including when multiple publishers list the same URL. Catalog reads are limited to 2 MiB
per page, enforced while receiving bytes. Manual URL registration and the separate Time.Now example remain available.

## MCP configuration and network boundary

Settings → MCP Servers configures explicit endpoints and optional bearer tokens. Saving a
new server connects and discovers its tools, then enables all discovered tools automatically.
Turn individual tools off afterward if needed. This initial grant is saved once; reconnects,
refreshes and restarts preserve those choices, and older registrations keep their exact
permissions. A changed endpoint still clears permissions. Enabled registrations (and new
registrations awaiting their first successful discovery) reconnect on Send after restart.
Discovery and calls do not run merely at app launch.
[Offline privacy mode](offline-privacy.md) blocks discovery and remote calls, including cached
clients, while keeping device-local skills, previously loaded iCloud skill instructions and
supporting files, and downloaded-model chat available. Uncached files need a successful
online read first; no scripts execute. Offline skill choices last for the session and do not
modify the shared preference. Failed calls
require an explicit retry; reconnecting does not replay them. Explicit context-count retry and
manual compaction can obtain missing tool metadata for older settings; ordinary counting
uses last-discovered definitions locally. No server is registered implicitly.
Sending while Settings is still discovering takes ownership of connection setup under the
Send task, so setup cannot race the submitted message and cancellation remains effective. The endpoint must use HTTPS; loopback HTTP is allowed for local developer tests.
Redirects are rejected, and the client has no cookie jar or shared credential store.
Credentials/query strings in endpoints are not supported. With iCloud Off, name, endpoint, selected tool names and validated last-discovered
definitions use excluded-from-backup device settings. Tokens use non-synchronizing,
When-Unlocked-This-Device-Only Keychain items. With iCloud On, registrations, grants and
readable bearer tokens use Settings/settings.json; schemas stay cached locally. Anyone
with folder access can read those keys. The app never adds keys to model prompts or chats.
See [shared settings](settings-sync.md) for migration, conflicts and configuration examples. Credentials are
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
HTTP/protocol errors and actual tool errors fail clearly. Completed tool results require a
content-block array with typed payloads and a boolean isError flag when present; malformed
results do not continue the model loop. SSE accepts LF, CRLF and CR line endings, ignores one leading UTF-8 byte-order mark, and rejects malformed UTF-8
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
Adding a server grants standing authorization for its first discovered tools; manual enabling
likewise authorizes automatic calls; there is no
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

## Automatic tool selection

Ask ordinary questions, such as "What time is it?", "Hvad er klokken i København?" or
"Find three time zones containing Europe." The local model selects from the enabled
catalog; users do not need to name a function or request a tool call explicitly. General
knowledge questions can be answered without calling a tool. A request may use a relevant
lookup chain, such as resolving a timezone before asking for its current time.

Each tool-enabled request includes a refreshed snapshot of enabled function names and
descriptions, selected-skill metadata and the device timezone alongside the original user
text. This helps existing chats use current capabilities even when older replies said
tools were unavailable. The same state is included in exact token counting and compaction
budgets. It is ephemeral inference
context: the app preserves the original saved message and excludes the added snapshot
from summarization input. The timezone is a device setting, not inferred geolocation;
actual calls may pass that timezone to the registered server for local-time questions.

Selection remains model-driven, with the same exact catalog/schema checks, cancellation,
result persistence and four-call limit. Language-model choices are not guaranteed for every
phrasing; no keyword router, guessed call, repair/retry path or substituted result is used.

## Model contract and evidence

The checkpoint's published [chat template](https://huggingface.co/sevren-ai/Embla1-4bit/blob/4d23eb7de21fc5b55c3051021c7550af1fdce0e8/chat_template.jinja)
provides a trained function/parameter format. The pinned Swift runtime only exposes text
roles, so Embla adapts that format in the leading system context and wraps actual results
in `tool_response` user turns. It does not claim the upstream Swift API has native tool roles.
Tool-enabled turns buffer output until the complete call or answer validates; ordinary
tool-free chat retains streaming. Stopping before validation discards the unfinished answer/call
buffer; completed tool requests/results have already been saved. A model request looks like:

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
values use Foundation Decimal’s supported precision. Untrusted JSON is checked against
its original numeric lexemes; fractions that would round or underflow are rejected at the
model/network boundary. Numbers are classified from their Decimal value before integer conversion, preventing
Foundation’s near-integer fractional coercion. Quoted digits remain ordinary string data. MCP integer parameter headers retain
the specification’s narrower safe-integer bound. Serialized tool JSON escapes literal `<`
with a JSON Unicode escape so server text cannot introduce runtime message boundaries or
close the tool envelope. JSON decoding still recovers the original data. Header discovery
walks schema-valued keywords only; default/const/enum/examples remain instance data.

Function names map exactly to a captured server/tool catalog; they are not inferred from
prose. Parameters declared exactly type string use the checkpoint's plain-text convention;
all other parameter values, including union types, must be JSON. A string in a union must
therefore be quoted (for example `"null"` differs from JSON `null`); the parser never guesses
a string from invalid JSON. Plain final answers need no JSON envelope. Unknown/multiple/incomplete calls,
duplicate/missing required parameters and output-limited responses fail without dispatch.
Arguments are validated before dispatch without coercion or numeric conversion. The supported
JSON Schema 2020-12 subset includes types (including unions), enum/const, nested properties,
required/additionalProperties, object/array/string size limits, items/uniqueItems, numeric
bounds/multipleOf, and allOf/anyOf/oneOf/not. String length counts Unicode scalars. Schema
nesting is limited to 32. Unsupported keywords (including references, pattern, format,
conditional and unevaluated constraints), other dialects and malformed constraints fail
clearly before execution; this is not a full JSON Schema validator. Annotation keywords
title, description, default, examples, deprecated, readOnly, writeOnly, $comment and
x-mcp-header do not modify arguments. No remote references are fetched.
There is no repair, guessed identifier, retry-until-execution or substituted tool result.
The loop uses greedy sampling, at most four registered-tool executions and five planning/answer
passes. Internal local summaries are separately bounded. Exact token counting includes skill
instructions, schemas, project memory, rolling summary and the growing exchange.

### Long-running calls and large results (#86, #87)

Discovery shares one 60-second absolute deadline across server information and every tool
catalog page. A tool call has a 20-minute absolute deadline,
including response headers and the entire JSON/SSE body. Keep-alives do not extend it. The
longer call budget accommodates research servers; Tavily’s official implementation polls
pro/auto research for up to 15 minutes ([primary source](https://github.com/tavily-ai/tavily-mcp/blob/70d4d47f9b96539ca143c940bd3562578923d56f/src/index.ts#L788-L810)). Embla waits for the supported synchronous MCP reply;
it does not invent a separate polling protocol or substitute a faster tool. Stop, background
and privacy cancellation still close the request. A timeout has an unknown remote outcome
and requires explicit retry; cancellation cannot undo remote work already started.

Before a tool continuation, the actual tokenizer counts the full proposed prompt with a
512-token answer reserve and 256-token headroom. If it is too large, the same local model
summarizes the complete tool result as quoted, untrusted data. Every source character is
processed in measured chunks; each chunk also fits its summary output reserve. Tokenizer
probes grow from a bounded starting fragment and check cancellation between probes. Chunks
prefer whitespace boundaries so ordinary URLs and identifiers stay whole; up to 128 raw
characters of previous-fragment overlap are included in each exact budget for unavoidable
splits. JSON escapes reserved delimiter characters without changing decoded source data. Notes are
carried forward across chunks, preserving relevant facts, exact identifiers, URLs and
uncertainty. Summaries can omit details. A visible transcript notice identifies the reduction;
the complete original result remains saved and available to inspect and copy.

A new tool continuation accepts only a nonempty, normally stopped summary that fits its
exact budget. The budget includes earlier results in the same tool turn and retained saved
results, including ones smaller than the maximum summary output. History compaction checks
its own prompt and output reserve before generation, separately from the reply budget.
Related result projections are saved together; the full continuation must still fit before
generation can start. Work is
bounded to 32 chunks and at most 1536 output tokens per chunk; a continuation needs at least
128 available summary tokens. No room, an incomplete summary, a chunk limit or a failed
projection save is an explicit error. There is no silent text truncation or substitute
answer. Saved raw output remains available after Stop/failure/restart. A later Send can
locally summarize a large completed result without re-executing it. Saved projections retain
the canonical request metadata; older records without an envelope retain their tool name. If
a growing tool exchange exhausts fixed context, an eligible older history prefix is compacted
before rebuilding the saved exchange, without replaying calls. Ordinary enabled-server
setup may still perform discovery. Committed summaries also drive subsequent context counts,
conversation compaction and optional cloud sync. Internal summary runs do not enter the
chat’s decode-speed average. A network/privacy interruption during the atomic save remains
latched even after connectivity returns: the committed notes survive, but continuation stops.
An inactive/active cycle during that save also cancels continuation while preserving the
completed atomic write.

See [validation and simulator scope](development.md#tool-result-continuation-validation).

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
review fixes in 28.327 s, then with strict schema validation and catalog refresh in
27.626 s, including returned `2026-11-16T08:04:47.873300+01:00`.
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
from opt-in actual-model/public-server tests. The current suite reports 143 presentation
and 41 core tests; eight actual-model cases are opt-in and skipped by default. The ten
simulator UI tests passed on the existing iPhone 17 Pro/iOS 27.2 simulator, including
skill access and no-network/no-token server registration/removal. No new simulator was
created. App-only UI screenshots are retained in the result bundle. Final hosted checks,
review and merge evidence are recorded in [#27](https://github.com/peterbb148/embla-chat/issues/27)
before delivery is declared. New-format real iCloud validation remains the separately
deferred #45, not a successful test implied by this implementation.

### Natural-question regression (#57)

The real-model regression enables all three Time.Now tools and covers implicit local time,
English/Danish city-time questions, timezone-name search and tool-free knowledge questions.
It also generates two no-access replies with tools disabled, enables the tools in that same
chat and retries the original request without naming a function. Returned clock values are
compared with the actual saved server result, allowing ordinary 12/24-hour formatting.
A further ordinary follow-up obtains a fresh result in that same chat.
The prior system-only prompt failed this existing-chat case; the refreshed current-request
capability context addresses it. Exact run results are recorded in #57 and its PR.


### Registry and multiple-server regression (#61)

The opt-in regression reads the actual official Context7 listing and uses its remote
endpoint through the same registration/discovery path, alongside Time.Now. Every discovered
tool is enabled, and both servers remain available for ordinary time and Python-documentation
library-ID questions. Answers are compared with actual returned clock values and library
identifiers, and saved transcripts are checked. Synthetic catalog fixtures separately cover
latest/active filtering, unsupported connections, publisher identity, opaque pagination,
HTTP errors and malformed responses. Exact live run/review/merge evidence belongs in #61.
The clock reply also added an incorrect unrequested weekday; #70 tracks investigation of
that answer-quality defect. Requested-field validation is not proof of every generated fact.

Local context planning reuses the validated saved catalog after pause/restart (#71), not a
live connection. Send still prepares actual clients and refreshes missing connections before
generation, and dispatch requires a live client plus the enabled/schema checks. With local settings, metadata persists atomically with the registration and is invalidated
durably before changing a credential. With shared settings, endpoint-bound keys/registrations
are committed together; connection-fingerprinted schemas stay cached on the device.
Name/permission-only edits preserve the catalog. MCP Server settings display every tool in
that catalog, including disabled tools and their descriptions, after restart or shared-settings
reload (#89). Turning a tool off retains its row; turning it back on uses the validated saved
schema without a discovery request. That does not create a live connection or authorize
disabled tools for model context/execution. Connection changes still invalidate saved schemas.
Failed writes leave the previous
configuration available. Planning only reconnects servers missing metadata. Count retry supports
Stop and cancels on inactivity. This does not send chats or credentials to the registry. Optional shared credential storage
is governed by the separate expanded iCloud consent.

### Inspecting tool responses (#91)

Tool records are collapsed by default in the chat. The tool name, progress/failure state and
any local-summary notice remain visible; the assistant's conversational answer is unchanged.
Open **Inspect response** to view the complete original request/result as selectable plain text
and use **Copy tool details**. Opening inspection pauses automatic following so a tall
response's beginning and collapse control stay in view. **Jump to latest** (or sending a
message) resumes following. Collapse it again to return to the compact transcript.
This applies to saved tool records too. Expansion is view state only and starts collapsed after
relaunch; it does not change saved output, model context, compaction, permissions or tool calls.
