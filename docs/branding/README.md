# Embla identity

The user approved this leaf design on 2026-11-15. It is an original modern interpretation,
not a historical Norse symbol. Embla is the first woman in Norse mythology, paired with
Ask, the first man. Her name is traditionally associated with elm (alm), but that
etymology is uncertain. Sources: [Store norske leksikon](https://snl.no/Embla_-_kvinnenamn)
and [Den Store Danske](https://lex.dk/Ask_og_Embla).

## Artwork and export

- `embla-leaf-source.png`: unmodified 1254 × 1254 opaque generated artwork.
- `prompt.txt`: exact generation prompt, using the built-in image generation tool.
- `../../EmblaChatApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png`: opaque
  1024 × 1024 export. The full square background is intentional; iOS supplies its mask.
- The app target includes `Assets.xcassets` in Resources and selects `AppIcon` in
  both Debug and Release. The single universal iOS entry supplies the required sizes.

Re-export from the repository root:

```sh
sips -z 1024 1024 docs/branding/embla-leaf-source.png \
  --out EmblaChatApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Validation

Source and export have no alpha channel. Project syntax passes `plutil -lint`.
Xcode 27.2 Release device build passed with signing disabled. The compiled Info.plist
selects `AppIcon` as `CFBundlePrimaryIcon`, and asset compilation produces the
Home Screen icon files. The 1024 px export and compiled 120 px icon were visually
inspected. Hosted Xcode 26.2 build and launch checks run on the pull request.
This change does not require reinstalling the app on the user's phone or clearing a chat.
