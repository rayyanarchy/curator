# Curator

A private, native iPhone and iPad reader for your Instagram data export.

Curator imports the ZIP you download from Instagram, keeps each account in its own isolated local vault, and lets you browse the media in a vertically stitched feed or a portrait grid. Everything is processed on-device.

> Curator is an independent project and is not affiliated with, endorsed by, or sponsored by Instagram or Meta.

## Features

- **Import** Instagram export ZIPs through the system file picker, with cancellable progress
- **Profiles**: each account lives in its own vault; switch, rename, delete, or add profiles from the profile drawer
- **Smart merging**: detects the account from the export, blocks exact re-imports, and de-duplicates media when you import an updated archive
- **Feed and Grid** tabs backed by the same sorted and filtered collection
- **Media drawer**: pull-down, resizable viewer with swipeable photos and autoplaying video
- **View Options**: sort, and choose which media categories are visible, saved per profile
- **Appearance**: System, Light, or Dark

The full, maintained list is in [FEATURES.md](FEATURES.md).

## Privacy

- Archives are read on-device. Nothing is uploaded, and there is no analytics or network access.
- Your original ZIP is opened through the system file picker and is never modified.
- Imported media is copied into private, app-managed storage, one vault per profile.
- Archive paths are validated before any file is extracted.

## Getting your Instagram export

Request a copy of your data from Instagram (in the app, look for **Accounts Center → Your information and permissions → Download your information**; exact menus change over time). Curator reads exports in HTML or JSON format. Save the ZIP to Files, then choose it from Curator's **Import Archive** button.

**Please don't commit personal exports to this repo.** They are ignored by `.gitignore`, and should stay that way.

## Requirements

- iOS / iPadOS 18.0 or later
- Xcode 27 (see `xcodeVersion` in `project.yml`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

The Xcode project is generated from `project.yml`.

```sh
xcodegen generate
open Curator.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project Curator.xcodeproj -scheme Curator \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

To run on a device, select your own development team under **Signing & Capabilities** and change the bundle identifier (`app.curator.ios`) to one you own.

## Tests

```sh
xcodebuild test -project Curator.xcodeproj -scheme Curator \
  -destination 'platform=iOS Simulator,name=<simulator name>'
```

The `CuratorImportSmoke` target is a small macOS command-line tool that runs the importer against an archive without the UI.

## Project layout

```
Curator/
  App/        App entry point and app-level state
  Models/     Vault and media models
  Services/   Archive import, storage, metadata, paths
  UI/         Feed, grid, media drawer, profile drawer
CuratorTests/ Unit tests
Tools/        ImportSmoke command-line tool
project.yml   XcodeGen project definition
```

## Dependencies

- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) for reading archives
- [SwiftSoup](https://github.com/scinfu/SwiftSoup) for parsing Instagram's HTML export

## Contributing

Issues and pull requests are welcome. If your change adds, removes, or alters a capability, update [FEATURES.md](FEATURES.md) in the same change. See [AGENTS.md](AGENTS.md) for the workflow notes used with AI coding tools.

## License

This project is open source and available under the [MIT License](LICENSE).
