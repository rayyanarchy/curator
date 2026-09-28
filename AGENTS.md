# Agent Guidance

Curator is a native iPhone and iPad app (iOS 18+) that imports Instagram data-export ZIPs into isolated, on-device profile vaults and lets the user browse the media. See `README.md` for the overview and `FEATURES.md` for the current capability list.

## Ground rules

1. **Keep `FEATURES.md` current.** When a change adds, removes, or alters a user-visible or backend capability, update `FEATURES.md` in the same change.
2. **`project.yml` is the source of truth for the Xcode project.** Change targets, settings, and dependencies there, then run `xcodegen generate`. Don't hand-edit `Curator.xcodeproj/project.pbxproj`. Re-run `xcodegen generate` after adding or removing source files.
3. **No personal signing details in the repo.** Don't commit `DEVELOPMENT_TEAM`, provisioning profiles, or certificates. Check with `grep -n DEVELOPMENT_TEAM Curator.xcodeproj/project.pbxproj` before committing.
4. **Privacy is a product requirement.**
   - No network requests, analytics, or crash reporting.
   - Never log or print captions, usernames, file names from an archive, or other personal content.
   - Never commit Instagram exports (`igexpt-*.zip`) or media extracted from them. Tests use small synthetic fixtures only.
5. **Treat archives as untrusted input.** Validate every entry path before extracting (guard against `..`, absolute paths, and symlinks). Don't weaken this when touching the importer.
6. **Ask before adding a dependency.** Current dependencies are ZIPFoundation and SwiftSoup (both MIT). New ones need to be permissive-licensed and compatible with App Store distribution (no GPL/AGPL).

## Project layout

| Path | Contents |
| --- | --- |
| `Curator/App` | App entry point and app-level state (`AppModel`) |
| `Curator/Models` | Vault and media models |
| `Curator/Services` | Archive import, vault storage, metadata writing, app paths |
| `Curator/UI` | Feed, grid, media drawer, profile drawer, shared components |
| `CuratorTests` | Unit tests |
| `Tools/ImportSmoke` | macOS command-line tool that runs the importer without the UI |

`Curator/Models` and `Curator/Services` are also compiled into the `CuratorImportSmoke` macOS target, so keep them free of iOS-only APIs (UIKit and similar).

## Build and test

```sh
xcodegen generate

# Build
xcodebuild -project Curator.xcodeproj -scheme Curator \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# Test (pick any installed simulator)
xcodebuild test -project Curator.xcodeproj -scheme Curator \
  -destination 'platform=iOS Simulator,name=<simulator name>'
```

## Conventions

- Swift 5 language mode with minimal strict concurrency (see `project.yml`). Don't raise these settings as a side effect of an unrelated change.
- Prefer native components: SF Symbols, system typography, and system-sized controls. Avoid custom chrome where a system control exists.
- Keep the main thread free. Thumbnail decoding, media filtering, and import progress are deliberately cached, coalesced, or done off the main thread. Preserve that when changing them.
- Profiles are isolated: no change should let one profile's media, preferences, or import history leak into another.
- Add or update tests in `CuratorTests` for model and logic changes.

## Definition of done

- The project builds and tests pass.
- `FEATURES.md` reflects the change.
- `git status` shows no build output, user data, or signing details.
