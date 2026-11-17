# Offline privacy mode

Embla monitors the system's network path across all interfaces with `NWPathMonitor`.
An unavailable path automatically pauses app-initiated networking and displays a thin
green outline, with **Privacy mode — network paused** on the chat screen. The outline
follows the full screen edge, including the system keyboard and presented sheets, without
intercepting touches or keyboard input. Entry/exit transitions are
announced to VoiceOver even when a modal covers the chat status.

A satisfied path only permits connection attempts; it does not verify the internet,
a particular MCP server, or a captive portal. Unknown and connection-required states
have explicit status text, without the green privacy indication. Wi-Fi off can still
leave cellular available; airplane mode can still leave Wi-Fi available. Embla does
not inspect radio switches or send third-party connectivity probes.

## What remains available

Downloaded-model inference, saved local chats/drafts, local compaction, and skills/actions
from the device profile or the last synced iCloud copy remain available. Enabled remote registrations do not force
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
preserved. Offline operation pauses new app access to iCloud/File Provider. Device-local saved
chats/drafts remain usable. Successfully loaded actions, skill instructions, supporting
files and settings are saved in a private device cache, isolated by the durably authorized
folder grant and excluded from backup. Offline reads use that same profile, including after
a restart; Embla never substitutes the separate Off profile. Settings snapshots also contain
the readable MCP keys already authorized for that folder. Remote calls remain blocked.

Actions and skill instructions are cached on successful reload; supporting files are cached
when successfully opened. Content not yet cached fails clearly and must be loaded while
connected first. An offline skill selection applies to this session through Send preparation;
it does not queue a change to the shared preference. Shared configuration edits and starter
file creation require connectivity. Reconnection refreshes the cloud source and restores its
shared skill choice. An already-prepared offline turn retains its validated skill and local
file capability across reconnects, without gaining remote tools. Explicit folder/consent
changes still revoke that turn. Cached reads run independently of blocked provider I/O.
Transient skill-read errors remain visible online and preserve the previous good offline
copy; confirmed changed, invalid or deleted content invalidates it. No online read error
silently selects an older cached copy. Confirmed missing or invalid supporting files remove
their generated cached copy; transient I/O errors preserve it. Corrupt generated skill
metadata reports an error offline. A connected reload rebuilds it from successfully read
authoritative source bytes. Instruction reads during resource access update or invalidate
the same metadata snapshot; a confirmed missing or replaced Skills directory invalidates
that folder snapshot. Already-prepared turns keep their pinned context through ordinary
refreshes; explicit folder/consent changes revoke them.
Coordinated file operations recheck the policy on entry and before reading/writing. Recovery
opens only a durably saved folder grant; pending or failed folder changes stay suspended.

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
integration tests separately exercise cancellation and file boundaries. All 236 unit/integration
tests passed (189 presentation, 47 core), including offline snapshot cold-start and folder
isolation checks. Review fixes cover on-demand connection upgrades
and preserve a long-lived HTTP session per client, with independent per-task admission and
cancellation. Simulator UI coverage checks light/dark appearance, Settings and Context sheets,
keyboard input, reconnect while the keyboard is already present, and rotation. Full-screen
pixel assertions require green at the top, bottom and both sides, including beside the
software keyboard. These are policy-injection checks, not evidence that the simulator
changed physical radios.

Physical iPhone checks verified fresh Time.Now calls over cellular with Wi-Fi off and over
Wi-Fi with airplane mode on. Airplane mode with Wi-Fi off showed privacy mode, no enabled
remote tools, and a successful local answer. The user requested that the outline also
surround the keyboard; the user confirmed full keyboard coverage on the installed phone
build. After reconnect,
Device Hub showed the border cleared, network availability and iCloud still On. The new
cached-data behavior is awaiting phone verification in #78. Successful personal-iCloud
synchronization was observed after the user confirmed scope; broader provider/cross-device/failure testing remains #45.

Phone testing exposed confusing Settings wording. A satisfied path now displays **Network
connection available**; individual service failures retain their actual errors. Older iCloud
consent has a direct **Review iCloud sync** action rather than directing users back to the
screen they already opened. This review still requires explicit confirmation and never
changes the global choice automatically. The connected-phone baseline showed the downloaded
model preserved, successful iCloud sync after user confirmation, and successful Time.Now
metadata refresh with three enabled tools. Radio-transition checks are tracked in #78.
