# FileExplorer

A native macOS file manager that reproduces the Windows 11 File Explorer UX —
built for people who know Windows Explorer's keyboard/mouse model by muscle
memory and find Finder's conventions hard to switch to.

Windows-style behavior, macOS-native under the hood: SwiftUI + AppKit,
QuickLook previews, Spotlight search, Finder tags, and full Trash integration.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+

## Building

```
open FileExplorer.xcodeproj
```

Build and run (⌘R) with the `FileExplorer` scheme.

The app is **not sandboxed** by design — it needs arbitrary filesystem
access to act as a Finder replacement, the same way Finder itself isn't
sandboxed. It requests the standard TCC permissions (Desktop, Documents,
Downloads, removable/network volumes) on first access to each.

## Features

- **Windows keyboard model**: Backspace = back, Delete = Trash, ⌥+arrows =
  back/forward/up, type-ahead selection, 2D arrow navigation in grid views
- **4 view modes**: Details (sortable/customizable columns), Icons, Extra
  Large Icons, List — plus Group By (type/date/size) with collapsible
  sections
- **Tabs**: ⌘T/⌘W/⌘⇧T, per-tab history and search
- **Split view**: two folders side by side for drag-and-drop move/copy
  between them
- **Rename**: Finder-faithful inline rename (base-name selection, extension
  change confirmation, slow-second-click to rename)
- **Search**: incremental folder-local filter, plus Spotlight-backed
  system-wide search and tag search
- **Previews**: QuickLook pane for images/PDF/text/video/audio, inline audio
  playback, video poster frames
- **File operations**: copy/move/rename/trash/permanent-delete with
  progress + conflict resolution, undo/redo, batch rename, ZIP compress/
  extract
- **Sidebar**: Favorites, Quick Access, iCloud Drive, mounted volumes
  (tree), Recent, Tags, Trash
- **Clipboard interop**: Cut/Copy/Paste syncs with the system pasteboard,
  so files copied in Finder can be pasted here and vice versa

## Known limitations

- No tab tear-off into a new window
- Conflict dialog shows a generic file-type icon, not a real thumbnail
  preview
- No admin-privilege elevation flow for permission-denied operations
- No disk-usage visualization (sunburst/treemap)
- No shortcut/column-preset customization UI

See `FEATURE_CHECKLIST.md` for the full original feature-parity plan
against Windows Explorer.

## Architecture

MVVM: one `TabViewModel` per tab (current path, history, selection) owned
by a per-window `WindowState`. File operations, clipboard, search, and
QuickLook each live behind a dedicated service in `Services/`. See inline
doc comments throughout — most non-obvious behavior (gesture conflict
avoidance, TCC handling, undo bookkeeping) is explained at the point where
it matters rather than here.

## File-operation safety and recovery

Transfers stage a cancellable, metadata-preserving copy on the destination
volume before committing. Same-location copy creates a new name; same-location
move does nothing. Replace preserves the previous item and supports Undo/Redo.
Folder conflicts include **Merge Folders**, which resolves child conflicts
individually. Long operations across windows use a shared queue.

Old targets, retired move sources and undone copies are preserved in private
`.FileExplorer-Recovery-*` directories. **Help → Recovery Folders…** opens these
locations; each recovery directory includes a JSON file identifying its original
location. Recovery data is never automatically deleted. This favors recovery
over disk usage: a cross-volume move can require space for an additional recovery copy. Same-volume moves commit by rename.
Only abandoned staging directories without recovery metadata, older than a day,
are cleaned at startup. Use the file manager to move unneeded recovery data to
Trash after checking it. Undo history is still in memory and belongs to a tab;
recovery files remain available after a tab closes or the app restarts.

Archives are extracted into a new unique folder. A streaming macOS libarchive
reader rejects absolute/traversing paths, symbolic/hard links, special files and
duplicate entries, and enforces 100,000-entry / 20 GiB limits. ZIP, TAR, 7z and
RAR depend on the codecs available in the system libarchive; encrypted archives
are not supported. Untrusted ownership, executable bits and extended attributes
are not applied during extraction. **Browse Archive…** supports selected-subtree
extraction. ZIP compression continues to use the system `ditto` tool.

Folder search adds a disk scan for non-indexed locations and optional local
UTF-8 text content search (up to 1 MiB per file). The UI explicitly offers the
next 500 results. Disk scans stop at 60 seconds or 50,000 matches and report
limits/read failures. Content scanning skips app packages, links and cloud files
that are not locally current; Spotlight may return other indexed formats.

Other additions: **File → Connect to Server…**, iCloud status/download/eviction
in the item menu, mounted volumes' per-user Trash entries, link/alias actions,
last-operation results/retry, and Settings for Backspace/Return behavior and
column presets. Finder receives file URLs on the clipboard and may interpret
Cut as Copy; Paste inside FileExplorer retains Cut = Move semantics.
Trash origins are remembered for items trashed by FileExplorer; unknown origins
are delegated to Finder with an explicit message instead of silently failing.

### Regression tests

With Xcode command-line tools and Python 3 installed:

```sh
bash Tests/run-core-tests.sh
```

The runner compiles the actual core services and creates temporary normal and
hostile archives. It does not modify user files. UI, real removable/network
volumes, iCloud accounts, release signing and notarization require separate
integration checks.
