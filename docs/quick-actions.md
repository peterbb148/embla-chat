# Quick actions (#37)

Quick-action cards appear above the composer on an empty chat. Tapping a prompt fills the
composer; edit it and press Send when ready. It never submits automatically or starts a
new chat. A different nonempty draft requires Replace draft confirmation; Cancel keeps it.
The same rule applies inside a project. Starting another chat and deleting model weights
leave the action configuration intact.

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
| `type` | Required `prompt` or reserved `skill`; unknown values are rejected. |
| `prompt` | Required nonempty string for prompt actions; exact text is preserved. |
| `skill` | Required nonempty reference for reserved skill actions. |

Labels, IDs and required content cannot be whitespace-only. Malformed JSON, missing/wrong
fields and duplicate IDs are errors; invalid configurations are not partially rendered.
This is Embla's format, rather than an automatic import of another app's proprietary format.

Skill cards are visibly unavailable and cannot fill/submit a prompt or run code. Standard
skill loading and actual MCP/tool execution remain #27 in Epic 5. Credentials do not belong
in action JSON. No credentials or remote-tool authentication are implemented here.

## Evidence boundary

Package tests use real temporary/coordinated local files and explicit provider fixtures.
They cover first-use defaults, external edits, ordering/disabled entries, validation,
non-overwrite behavior, missing/corrupt files without regenerated defaults, Off-mode provider
isolation, waiting for durable consent, explicit cloud failure without a local substitute,
late-result rejection after Off, and changed/skill selections refusing to produce a prompt.

Production simulator checks exercise the actual card/composer/confirmation/Settings path
without downloaded weights or fake assistant replies. Real model inference and project-memory
behavior have separate host/device evidence; a filled composer is not a generated response.
Actual new-format iCloud provider checks remain explicitly deferred to #45 by the user.

Local validation: the package suite reports 132 tests, and all nine production UI tests
passed on the existing iPhone 17 Pro/iOS 27.2. The focused action case also retains app-only
screenshots in its xcresult; inspection shows the horizontally scrolling cards, filled
composer above the keyboard, and native replacement confirmation. No assistant response is
fabricated. The actual simulator actions.json matches the portable example structurally.

Compiled-product inspection caught Xcode omitting UIFileSharingEnabled when provided only
as a generated build setting. The app now uses an explicit partial Info.plist merged with
the generated values, following [Apple's build-setting behavior](https://developer.apple.com/documentation/Xcode/build-settings-reference).
Both sharing keys are true in the built simulator app. CI checks the actual Release bundle
keys before running UI tests, so source-only declarations cannot silently regress this path.
Actual personal-iCloud configuration transfer is not claimed; it stays deferred to #45.
