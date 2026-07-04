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
