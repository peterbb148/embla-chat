# Offline privacy mode

Embla monitors the system's network path across all interfaces with `NWPathMonitor`.
An unavailable path automatically pauses app-initiated networking and displays a thin
green outline, with **Privacy mode — network paused** on the chat screen. The outline
covers sheets and does not intercept touches or keyboard input. Entry/exit transitions are
announced to VoiceOver even when a modal covers the chat status.

A satisfied path only permits connection attempts; it does not verify the internet,
a particular MCP server, or a captive portal. Unknown and connection-required states
have explicit status text, without the green privacy indication. Wi-Fi off can still
leave cellular available; airplane mode can still leave Wi-Fi available. Embla does
not inspect radio switches or send third-party connectivity probes.

## What remains available

Downloaded-model inference, saved local chats/drafts, local compaction, and skills/actions
from the device profile remain available. Enabled remote registrations do not force
discovery before offline chat. Remote tools are excluded from the current model capabilities;
the model receives an explicit limitation, not a fabricated live result. Existing historical
tool outputs stay in the transcript and are not represented as newly retrieved data.

The same synchronous gate admits MCP discovery/calls, registry browsing and model download
tasks immediately before resume. Path loss revokes admission and cancels in-flight tasks.
Existing clients/cached catalogs cannot bypass the gate. A response that races path loss
is checked again before use. Normal HTTP/authentication/protocol errors remain errors;
they do not turn on a false privacy indication. Cancellation cannot undo data already sent
or server-side effects. Failed tool calls require an explicit retry and are never replayed
just because the connection returns. A turn prepared offline stays without remote tools
until a new submission, even if connectivity returns while the model is answering.

## iCloud boundary

The global iCloud preference, selected folder, permissions and readable settings file are
preserved. Offline operation pauses new app access to cloud chats, settings, skills and
actions. Device-local saved chats/drafts remain usable. Cloud skills/actions/settings are
unavailable while paused; Embla does not silently substitute the separate Off profile.
Coordinated file operations recheck the policy on entry and before reading/writing.

**The outline is not a system-wide network isolation guarantee.** iCloud Drive/File Provider
may finish or later resume transfers already handed to the system. Embla cannot cancel all
OS-managed transfers, control other applications, or retract transmitted data. Reconnecting
can resume consented chat/settings synchronization, including local edits made offline.
Turn iCloud Off if those edits should not later synchronize; existing cloud files remain.
The app hides its outline before reopening network admission. Registrations, credentials
and individual tool grants survive these transitions.

## Validation scope

Unit/integration tests cover gate transitions, stale UI acknowledgements, no dispatch for
cached calls/discovery/registry/download, actual loopback cancellation, retained registrations,
local skill resources, local inference/compaction with enabled remote servers, and cloud
entry rejection. These use explicit injected policy states and synthetic fixtures, not
pretend radio changes or cloud-provider transfer results. Simulator UI tests use a Debug-only
policy fixture; Release always uses the system path monitor. Real radio transitions,
cellular/Wi-Fi combinations and Apple-managed transfers require physical-device validation.

### Development checkpoint

On 2026-11-17 the real pinned model on the Mac completed offline manual summarization
and exact codename recall with an enabled remote registration and no discovery. Synthetic
integration tests separately exercise cancellation and file boundaries. All 226 unit/integration
tests passed (179 presentation, 47 core). Review fixes cover on-demand connection upgrades
and preserve a long-lived HTTP session per client, with independent per-task admission and
cancellation. Two final simulator UI tests passed in light/dark appearance with chat, Settings and Context sheets, the keyboard
boundary, and reconnect while the keyboard was already present. These are policy-injection checks,
not evidence that the simulator changed physical radios. Physical Wi-Fi/cellular/airplane-mode
checks and actual personal-iCloud provider transfer remain outstanding (#78 and #45).
