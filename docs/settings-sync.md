# Shared settings

The optional global iCloud switch covers saved chats, project memory, Skills, Actions and
settings. Select the `EmblaChat` folder in iCloud Drive. Existing users must confirm the
expanded scope before any cloud access resumes. No Apple Developer Program cloud container
is used: the app coordinates ordinary files inside the folder granted through Files.

## Configure once

With iCloud enabled, open Settings → MCP Servers to add or edit a server. Its registration,
permissions and manually supplied bearer token are saved in `Settings/settings.json`.
Alternatively edit that file in your selected iCloud folder. A minimal document is:

```json
{
  "formatVersion": 1,
  "selectedSkill": null,
  "servers": [
    {
      "id": "D6061404-626B-46B0-8818-A2A2B4C04EE1",
      "name": "Tavily",
      "endpoint": "https://mcp.tavily.com/mcp/",
      "enabledTools": [],
      "enableToolsOnFirstDiscovery": true,
      "credential": {
        "endpoint": "https://mcp.tavily.com/mcp/",
        "bearerToken": "REPLACE-WITH-YOUR-OWN-KEY"
      }
    }
  ]
}
```

Use a unique UUID for each registration. Enter your own Tavily API key privately in the
app or file, never in a GitHub issue or source repository. Tavily documents API-key
[Authorization-header authentication](https://docs.tavily.com/documentation/mcp).
Embla sends `Authorization: Bearer <key>`. Browser OAuth is not implemented. The placeholder
above is documentation only and cannot authenticate. After editing, tap **Reload settings**
in Settings. The app also rereads settings when returning to the foreground and before
Send/manual context preparation. It does not connect to servers just to read configuration.
First successful discovery enables all tools when `enableToolsOnFirstDiscovery` is true;
afterward the exact `enabledTools` array controls permission, including an empty array.

Keys are **plaintext** in this file, as explicitly chosen for this workflow. Anyone or any
app with access to the folder can read them. Do not share this folder, commit it, or paste
its contents into diagnostics. The app does not put keys into prompts or chat files.
The repeated credential endpoint must exactly match the registration endpoint. An endpoint
edit with an old credential binding is rejected. In the app, changing endpoints removes
the old key and tool permissions. When editing the file, explicitly supply the intended
new endpoint/key/grants. Remove `credential` to stop authenticating; remove a server entry
to remove that registration. No device-local key is substituted for a missing cloud key.

Enable iCloud and select the same folder on another installation. Once iCloud Drive has
materialized the file, registrations, grants and credentials can be used without re-entry.
An open editor retains a source/name/endpoint/key baseline. If another device changes
those values, saving fails until you explicitly reload saved settings. Reload awaits a fresh shared document and selected-skill loading, then discards
unsaved form fields; current permission toggles are preserved by name-only form saves.

The app reports file availability/write completion, not a guarantee that another device
has received it. Actual authentication/discovery errors remain visible.

## Migration, conflicts and deletion

The local MCP profile remains intact. On first enable, an absent shared file is created
from the local registrations, endpoint-bound Keychain credentials and selected skill.
If both profiles contain different settings, synchronization pauses with explicit choices
in Settings. **Retained settings** uses this device's profile; **Shared settings** uses the
current cloud document. Additional iCloud conflict versions are separately selectable.
Choosing a version replaces the whole settings document, including its keys and grants.
Review the file if you need to combine configurations before choosing. No automatic merge
or last-writer-wins policy silently drops registrations.

Reads and writes run on a storage actor so a stalled provider cannot block the UI or Off.
Results are applied only to the same active source/revision. Off synchronously revokes
pending storage access; reads that finish later cannot create a settings file or export
local keys. Writers check revocation again inside coordination before mutation. Writes compare the entire previously read document and conflict versions inside file
coordination. A stale save fails and asks for reload; it does not overwrite another device's
edit. A deleted previously observed document prompts a choice between retained settings
and an explicitly empty configuration. Invalid/oversized JSON or broken credential bindings
fail visibly and are never replaced with defaults. Settings documents are limited to 1 MiB
and 64 servers. A successful file write is not a reported successful cloud upload.

Off stops app reads/writes of cloud settings and returns to the original device-local
profile. It retains cloud files and cloud credentials there; iCloud Drive can finish
transfers already queued by the OS. Local credentials still use device-only Keychain.
Shared keys are not copied to that Keychain. Re-enable reads the shared document again;
changes made to the local profile while Off require an explicit migration choice when
profiles differ. Removing a shared key does not delete a separate local-profile key.

## Settings inventory

| Setting/content | Storage and behavior |
| --- | --- |
| MCP names, endpoints, first-discovery grants, enabled tools | Shared settings when On; original local servers.json when Off |
| MCP bearer tokens | Readable shared settings when On; endpoint-bound device-only Keychain when Off |
| Selected skill | `selectedSkill` name in shared settings when On; local skill.json when Off. Applies across chats; the exact skill file is revalidated before generation |
| Portable skills | Existing `Skills/<name>/SKILL.md` and supporting files; device Documents/Skills when Off |
| Quick Actions: prompts, skill references, ordering, enabled state | Existing `Actions/actions.json`; device Documents/Actions when Off. Future action fields belong to that same file |
| Chats, summaries, projects, saved project memory | Existing Chats/ActiveChat.json, under the same explicit global consent |
| iCloud switch, scope consent, folder grant | Device-local. Another device must explicitly enable access; configuration cannot enable its own cloud access |
| Active chat, drafts, editor text, keyboard/sidebar state | Device-local/transient; not shared settings |
| Downloaded model, verification/progress, runtime/session/metrics | Device-local. Fixed model and generation policy are code, not user-configurable preferences |
| Tool schemas, live clients, selected skill contents | Derived device-local data, not shared registration authority. Catalog cache is keyed by each connection fingerprint, including endpoint and credential changes; name/permission edits retain validated schemas |
| Registry search, browsing cursor, errors, in-progress work | Transient; not user configuration |

Skill selection is a global preference; changing chats preserves it. A missing/invalid
selected skill is an error, not an instruction-free replacement. Selecting None persists
that choice. Skills and Actions remain independently user-edited files, not duplicated in
settings.json. Their existing validation/source rules still apply.

Local tests cover two independent installations over coordinated temporary files, migration,
stale writes, keys/grants/deletions, corrupt data, and Off/consent boundaries. They do not
prove personal iCloud transfer, account authentication, or cross-device availability; real
provider validation remains separately tracked in #45.
