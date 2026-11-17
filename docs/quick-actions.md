# Quick actions

Quick actions appear as naturally sized, wrapping bubbles in an empty chat. All enabled
entries remain in configured order; there is no sideways carousel or ranked subset. Large
catalogs can use the transcript's normal vertical scrolling. In an ongoing chat, tap the
lightning button beside the context indicator to show or hide the same bubbles. Selecting
one keeps the current chat and closes the chooser after successful application. Normal Send
also closes the chooser when the new user turn is appended, restoring response auto-scrolling.

By default, a prompt fills the composer for editing. Set `autoSend` to `true` to send its
configured prompt immediately through the normal Send path; these bubbles have a small
send arrow. A different nonempty draft requires **Replace draft** or **Replace and send**
confirmation. Cancel keeps the draft and sends nothing. Confirmation belongs to the exact
chat, transcript, draft and loaded action: navigating, adding another turn, editing the draft
or changing sources invalidates it. Edited messages invalidate it even when their IDs stay the
same. Send is disabled while an action is preparing; a late
skill-selection result cannot submit after an intervening turn, even if the draft text matches again.

Immediate sending requires a verified model, available settings/skill and ready chat storage.
The selected skill document is re-read before replacement/submission; a cached catalog entry
alone cannot authorize an unavailable skill. Preflight failures leave the draft unchanged
and are never queued for a later send. Repeated taps cannot submit duplicates while selection or generation is underway.
After submission, file, generation, tool and storage errors follow normal Send behavior.
The same rules apply inside projects. New Chat and model deletion retain action configuration.

## Files and storage mode

The one global iCloud choice selects the action source:

- Off: `On My iPhone/Embla Chat/Actions/actions.json` in the app's Documents directory.
  The Actions folder is excluded from automatic iCloud backup. Chats, drafts, folder grants
  and model weights remain in private Application Support, outside the shared Documents area.
- On: `Actions/actions.json` inside the EmblaChat root already selected for chat storage.
  The folder is read only after the iCloud preference is saved and its expanded scope is
  confirmed. A paused legacy consent or failed preference save cannot authorize a config read.

Open Settings > Manage quick actions to see the selected source, Reload actions and errors.
Edit/copy the JSON with a text editor through Files, Finder file sharing, or another device
using the selected iCloud folder. Reload after edits; returning to the foreground also reloads.
There is no live file watcher. A confirmation rechecks the currently loaded action so a
configuration/source change cannot silently replace a draft with a different prompt.

Successfully loaded iCloud actions are also saved in a private device cache tied to the
authorized folder. In airplane mode, the last synced copy remains selectable after app
restart, including normal draft replacement and auto-send behavior. The app does not open
the cloud provider offline or replace those actions with the separate device profile.
If no copy has been saved yet, reconnect and reload first. Shared-file creation/editing
requires connectivity; reconnection refreshes the source.

The app enables Apple's `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` keys
for its Documents folder, following [Apple's File Provider guidance](https://developer.apple.com/documentation/FileProvider?language=swift).
It does not expose the private chat archive or model directory through file sharing.

Three starter prompts are installed once in the on-device file. That first-use initialization
is recorded privately. Deleting or corrupting the file later produces an error, not regenerated
cards. An On source never substitutes the local file if the cloud file is missing or invalid.
Create starter actions is an explicit repair/setup action and writes only if the chosen file
is absent. Existing user configurations, including invalid files, are kept. Reads/creation are
coordinated with the file provider. Creation uses [non-overwriting writes](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/withoutoverwriting),
not an atomic replacement that could overwrite a user's file. Errors remain visible.

Turning cloud Off cancels pending app requests, selects the on-device configuration and rejects
late cloud results. Operations already handed to a provider may finish. No new cloud operation
is requested in Off mode, even if an old bookmark is retained. Config reads do not upload a
draft or transcript; chat/project synchronization follows its separate existing consent flow.

## Version-1 configuration contract

Copy [the starter file](../examples/actions.json), then edit the fields below:

```json
{
  "formatVersion": 1,
  "actions": [
    {
      "id": "draft-email",
      "label": "Draft an email",
      "order": 10,
      "enabled": true,
      "autoSend": false,
      "type": "prompt",
      "prompt": "Help me draft an email. Ask who it is for and what I want to say."
    }
  ]
}
```

| Field | Contract |
| --- | --- |
| `formatVersion` | Required integer, currently 1. Other versions fail visibly. |
| `actions` | Required array; an empty array intentionally shows no cards. |
| `id` | Required nonempty string, unique across enabled and disabled entries. |
| `label` | Required nonempty display text. |
| `order` | Required integer; ascending order, with file order breaking ties. |
| `enabled` | Required Boolean; false entries are omitted from the cards. |
| `autoSend` | Optional Boolean, missing defaults to false. True sends immediately and requires a nonempty configured prompt for either action type. Null and other types are invalid. |
| `type` | Required `prompt` or `skill`; unknown values are rejected. |
| `prompt` | Required nonempty string for prompt actions; exact text is preserved. |
| `skill` | Required name of a valid copied skill for skill actions. |

Labels, IDs and required content cannot be whitespace-only. Malformed JSON, missing/wrong
fields and duplicate IDs are errors; invalid configurations are not partially rendered.
This is Embla's format, rather than an automatic import of another app's proprietary format.

Skill cards explicitly select a valid copied skill from the current Skills source. An optional
`prompt` fills the draft with replacement confirmation; without one the existing draft is kept.
An immediate skill action must supply its own nonempty prompt; it never submits an unrelated
existing draft. Actions do not run scripts or register/enable MCP servers. Registered tools
can run automatically through the ordinary Send path. Missing/changed/invalid skills fail visibly. Credentials do not belong in action JSON; see [skills and MCP](skills-and-tools.md).

## Evidence boundary

Package tests use real temporary/coordinated local files and explicit provider fixtures.
They cover first-use defaults, external edits, ordering/disabled entries, validation,
non-overwrite behavior, reapplying backup exclusion after folder replacement, missing/corrupt files without regenerated defaults, Off-mode provider
isolation, waiting for durable consent, explicit cloud failure without a local substitute,
late-result rejection after Off, and changed/skill selections refusing to produce a prompt.

Production simulator checks exercise the actual card/composer/confirmation/Settings path
without downloaded weights or fake assistant replies. Real model inference and project-memory
behavior have separate host/device evidence; a filled composer is not a generated response.
Actual new-format iCloud provider checks remain explicitly deferred to #45 by the user.

The wrapping-cloud UI checks cover the starter catalog without weights. An additional
explicit saved-archive fixture exercises ten bubbles, the ongoing-chat toggle, draft Cancel
and replacement, same-chat retention, and an immediate action rejected before draft mutation
because the model is absent. The assistant fixture is labelled as saved synthetic UI data;
it is not generated output. The fixture-only test skips unless that archive is deliberately
seeded; a default-suite skip does not establish this coverage. Package fixtures separately
exercise actual Send orchestration, duplicate rejection, skill instructions and storage failure.

Compiled-product inspection caught Xcode omitting UIFileSharingEnabled when provided only
as a generated build setting. The app now uses an explicit partial Info.plist merged with
the generated values, following [Apple's build-setting behavior](https://developer.apple.com/documentation/Xcode/build-settings-reference).
Both sharing keys are true in the built simulator app. CI checks the actual Release bundle
keys before running UI tests, so source-only declarations cannot silently regress this path.
Actual personal-iCloud configuration transfer is not claimed; it stays deferred to #45.

## Repeating the explicit simulator fixture

Use the existing test simulator with iCloud Off and no model weights. Build the UI-test
product first using the commands in [development](development.md), then run:

```sh
python3 scripts/test-action-cloud.py --device EXISTING_SIMULATOR_UDID \
  --derived-data build/Epic4Simulator
```

This explicitly installs the built app, temporarily replaces its local archive and actions
with synthetic UI fixtures, and runs only `testQuickActionCloudFromExplicitFixture`. It
creates no simulator. It restores the original archive, action configuration and first-run initialization marker
even if the test fails, looking up the
container again because Xcode can relocate it. Logs and screenshots stay under ignored
`build/action-cloud-*`. Temporary private backups are deleted after success; failed runs
retain them there for recovery. A skipped fixture test is treated as failure by the helper.
No model output or personal iCloud replication is inferred from this presentation test.
