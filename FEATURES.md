# Curator Features

The inventory of what Curator does today. Update this file whenever app functionality is added, changed, or removed. In shared work, the agent making a feature change updates this list in the same change.

## Backend

### Import and validation

- Reads Instagram archive ZIP files.
- Validates archive paths before extracting files.
- Parses Instagram HTML and JSON export data to find media.
- Detects a profile name and stable account identity from Instagram export data.

### Profiles and storage

- Imports media into private, app-managed storage.
- Stores every profile instance in its own isolated vault.
- Persists multiple local profiles and their media indexes.
- Persists media category preferences separately for each profile.
- Remembers the last-used profile and each profile's latest imported archive filename.
- Renames and deletes a single profile vault without changing other instances.

### Duplicates and merging

- Tracks imported archive checksums and prevents exact archive re-imports.
- Prevents duplicate media when merging an updated archive into an existing profile.

### Performance

- Generates thumbnails for grid display.
- Caches and coalesces thumbnail decoding.
- Derives filtered media off the main thread.
- Coalesces import progress updates to keep interactions responsive.

## Frontend

### App shell

- Uses the Curator Icon Composer app icon on supported iPhone and iPad installations.
- Opens directly to the last-used profile as the app's main page.
- Uses the imported profile's name as the navigation title after import.
- Uses a sticky inline-large system toolbar title for Curator and imported profile names.
- Uses native SF Symbols, system typography, and system-sized toolbar controls throughout the interface.
- Persists an app-wide appearance choice with System, Dark, and Light options.

### Import flow

- Lets the user choose an Instagram archive ZIP from the system file picker.
- Shows a centered empty state with a bottom Import Archive action when no profiles exist.
- Prompts in a native alert to keep or edit the detected profile name, with Cancel and Done actions.
- Shows determinate, cancellable archive import progress in the main app surface.
- Shows an import error if the archive cannot be processed.
- Shows a clear empty state before an archive is imported and when an archive has no media.

### Feed and Grid

- Provides Feed and Grid tabs backed by the same sorted and filtered media collection.
- Keeps the navigation and tab chrome visible while the feed scrolls.
- Displays imported media in a vertically stitched, view-aligned feed with the focused item centered in the viewport.
- Autoplays the focused video in the feed and pauses videos as they move out of focus.
- Displays imported media as edge-to-edge, portrait-format thumbnails in a three-column grid.
- Marks every grid item with the same native SF Symbol used for its View Options category.

### Media drawer

- Opens tapped media in a pull-down, resizable drawer with medium and large positions.
- Shows media in rounded cards at their original aspect ratios, with adjacent items peeking at the drawer edges.
- Swipes horizontally between adjacent media while keeping the focused item centered.
- Autoplays focused videos in the native system player with playback controls hidden.

### Sorting and filtering

- Provides one native top-right menu in both tabs with direct sort choices and a nested "View Options" menu matching the five design categories.
- Keeps the nested media menu open while multiple media categories are selected or unselected.
- Filters each profile's feed and grid using its own saved preferences without deleting hidden media.

### Profile management

- Shows a system profile button visually separated from filtering with the platform's standard toolbar spacing.
- Opens profile management in a full-screen drawer for switching, renaming, deleting, and adding profiles.
