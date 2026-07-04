//
//  FileListView.swift
//  FileExplorer
//
//  Dispatcher — picks one of three views (Icons / List / Details)
//  based on the @AppStorage view-mode setting. The Details mode lives
//  in this file as `DetailsTableView` since it's the default and most
//  feature-rich; Icons and List modes are in their own files.
//

import SwiftUI
import AppKit

struct FileListView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var folderModes = FolderViewModeService.shared
    @AppStorage("fe.viewMode") private var viewModeRaw: String = FileViewMode.details.rawValue

    var body: some View {
        let mode = effectiveMode
        Group {
            // Grouping overrides the chosen view mode — Windows Explorer
            // does the same. To go back to icons/list/details the user
            // picks "Group by → None".
            if tab.groupBy != .none {
                GroupedListView(tab: tab)
            } else {
                switch mode {
                case .extraLargeIcons: IconsGridView(tab: tab, sizeMode: .extraLargeIcons)
                case .icons:           IconsGridView(tab: tab, sizeMode: .icons)
                case .list:            CompactListView(tab: tab)
                case .details:         DetailsTableView(tab: tab)
                }
            }
        }
        .overlay { emptyStateOverlay }
        // Stop inline audio preview when the folder changes — fires
        // once here regardless of which view mode is active.
        .onChange(of: tab.currentURL) { _, _ in
            AudioPreviewService.shared.stop()
        }
    }

    /// Per-folder preference (set explicitly by the user) wins. Falls
    /// back to the global default — which the View menu also updates
    /// so unseen folders pick up whatever was last selected.
    private var effectiveMode: FileViewMode {
        if let folder = folderModes.mode(for: tab.currentURL) {
            return folder
        }
        return FileViewMode(rawValue: viewModeRaw) ?? .details
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if tab.permissionBlockedURL != nil, let err = tab.errorMessage {
            // TCC-blocked folder — give the user a concrete next step.
            ContentUnavailableView {
                Label("Access Denied", systemImage: "lock.shield")
            } description: {
                Text(err)
            } actions: {
                Button("Open System Settings") {
                    PermissionGuide.openFullDiskAccessSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let err = tab.errorMessage {
            ContentUnavailableView(
                "Cannot read folder",
                systemImage: "exclamationmark.triangle",
                description: Text(err)
            )
        } else if tab.items.isEmpty {
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("This folder has no items.")
            )
        }
    }
}

// MARK: - Details mode (Table — default)

struct DetailsTableView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var clipboard = ClipboardService.shared
    @ObservedObject private var trashCache = TrashLocationCache.shared
    @AppStorage("fe.showExtensions") private var showExtensions: Bool = true

    /// Column visibility + order + width persistence. The Table builder
    /// reads/writes this; it's Codable, so we round-trip through Data in
    /// @AppStorage. Per-column `.customizationID` below links headers to
    /// their entries in this state.
    ///
    /// Initial state: hide the "optional" columns so a fresh user sees
    /// Finder-like defaults. They can opt into the rest via the column-
    /// header context menu (right-click any header → toggle column).
    @State private var columnCustomization: TableColumnCustomization<FileItem> = {
        var c = TableColumnCustomization<FileItem>()
        c[visibility: "dateCreated"]      = .hidden
        c[visibility: "dateAccessed"]     = .hidden
        c[visibility: "extension"]        = .hidden
        c[visibility: "tags"]             = .hidden
        c[visibility: "parentPath"]       = .hidden
        c[visibility: "originalLocation"] = .hidden
        return c
    }()
    @AppStorage("fe.columnCustomization") private var columnCustomizationData: Data = Data()

    // Slow-second-click → rename for the Table. SwiftUI's `Table` has no
    // per-row click callback, so we observe clicks with a PASSIVE
    // NSEvent monitor (returns events unchanged → native selection /
    // double-click untouched). It pairs mouseDown↔mouseUp to tell a
    // click from a DRAG (a drag moves the cursor) so dragging a selected
    // row to move it no longer arms a rename. See TableRenameClickDetector.
    @State private var renameDetector = TableRenameClickDetector()

    var body: some View {
        Table(of: FileItem.self,
              selection: $tab.selectedIDs,
              sortOrder: sortOrderBinding,
              columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \FileItem.name) { item in
                nameCell(for: item)
            }
            .width(min: 160, ideal: 320)
            .customizationID("name")

            TableColumn("Date Modified", value: \FileItem.dateSortableString) { item in
                Text(formatDate(item.dateModified))
                    .feFont(size: 13)
                    .foregroundStyle(.secondary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
            }
            .width(min: 130, ideal: 170)
            .customizationID("dateModified")

            TableColumn("Type", value: \FileItem.typeLabel) { item in
                Text(item.typeLabel)
                    .feFont(size: 13)
                    .foregroundStyle(.secondary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
            }
            .width(min: 90, ideal: 130)
            .customizationID("type")

            TableColumn("Size", value: \FileItem.sizeSortableInt) { item in
                Text(formatSize(item))
                    .feFont(size: 13)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            .customizationID("size")

            // — Optional columns (hidden by default, opt-in via header
            // context menu). Keeping them in the builder means
            // TableColumnCustomization can offer them in its menu.

            TableColumn("Date Created", value: \FileItem.dateCreatedSortableString) { item in
                Text(formatDate(item.dateCreated))
                    .feFont(size: 13)
                    .foregroundStyle(.secondary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
            }
            .width(min: 130, ideal: 170)
            .customizationID("dateCreated")

            TableColumn("Date Accessed", value: \FileItem.dateAccessedSortableString) { item in
                Text(formatDate(item.dateAccessed))
                    .feFont(size: 13)
                    .foregroundStyle(.secondary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
            }
            .width(min: 130, ideal: 170)
            .customizationID("dateAccessed")

            TableColumn("Extension", value: \FileItem.fileExtension) { item in
                Text(item.fileExtension.isEmpty ? "—" : item.fileExtension)
                    .feFont(size: 13)
                    .foregroundStyle(item.fileExtension.isEmpty ? .tertiary : .secondary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
            }
            .width(min: 60, ideal: 80)
            .customizationID("extension")

            TableColumn("Tags", value: \FileItem.tagsSortable) { item in
                tagsCell(for: item)
            }
            .width(min: 70, ideal: 110)
            .customizationID("tags")

            // "Path" column — really only useful in Spotlight mode when
            // results come from arbitrary folders. Hidden by default;
            // the user can enable it via the column-header menu.
            TableColumn("Path", value: \FileItem.parentPath) { item in
                Text(item.parentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 120, ideal: 240)
            .customizationID("parentPath")

            // "Original Location" — only meaningful for items in
            // Trash. Falls back to "—" elsewhere. AppleScript-backed
            // lookups are now triggered per-cell on `.onAppear`, so
            // only items the user actually scrolls into view incur
            // the (slow) Finder round-trip. Optional column users
            // can keep this hidden and pay zero AppleScript cost.
            TableColumn("Original Location") { item in
                Text(originalLocationText(for: item))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onAppear {
                        if tab.currentURL.standardizedFileURL == TrashHelper.trashURL,
                           trashCache.parent(of: item.url) == nil {
                            TrashLocationCache.shared.prefetch([item.url])
                        }
                    }
            }
            .width(min: 120, ideal: 240)
            .customizationID("originalLocation")
        } rows: {
            // Explicit rows so each can vend an NSItemProvider — this
            // enables the Table's NATIVE row dragging: the entire row is
            // a drag handle (not just the 16pt icon), and dragging one
            // of several selected rows carries the WHOLE selection,
            // exactly like Finder. The previous per-icon `.draggable`
            // could only ever carry the single grabbed file.
            ForEach(tab.visibleItems) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .onAppear { restoreColumnCustomization() }
        .onChange(of: columnCustomization) { _, newValue in
            persistColumnCustomization(newValue)
        }
        // Keep the shift-click anchor in sync with Table's built-in
        // selection logic. Whenever the selection narrows to a single
        // row (i.e. the user just clicked), promote it to the anchor so
        // a later ⇧-click in any other view mode extends from the same
        // pivot the user just established.
        .background(RenameProbeView { renameDetector.setProbe($0) })
        .onChange(of: tab.selectedIDs) { _, newValue in
            if newValue.count == 1, let only = newValue.first {
                tab._setAnchor(only)
            }
            renameDetector.selectionChanged(newValue)
        }
        .onAppear { renameDetector.start(tab: tab) }
        .onDisappear { renameDetector.stop() }
        .onChange(of: tab.renamingItemID) { _, _ in
            renameDetector.renameDidChange()
        }
        .contextMenu(forSelectionType: URL.self) { selection in
            contextMenu(for: selection)
        } primaryAction: { selection in
            // Double-click cancels a pending slow-click rename → opens.
            renameDetector.cancelArm()
            openSelection(selection)
        }
        // Background drop → into the current folder. This must be an
        // APPKIT drop target (planted behind the Table), not a SwiftUI
        // `.dropDestination` on the Table: the Table is AppKit-backed
        // and the SwiftUI modifier never fires there on macOS 14, so
        // dropping on the empty area silently did nothing. Folder-row
        // cells keep their own SwiftUI drop targets, which sit ABOVE
        // this catcher and win where present.
        .background(TableDropCatcher(tab: tab))
        .feKeyboardNavigation(tab: tab)
    }

    // MARK: - Cell

    @ViewBuilder
    private func nameCell(for item: FileItem) -> some View {
        HStack(spacing: 6) {
            // Dragging is provided by the ROW (TableRow.itemProvider —
            // native table drag), so the whole row is the drag handle
            // and multi-selections drag together. No `.draggable` here:
            // a second SwiftUI drag source on the icon would race the
            // native row drag.
            ThumbnailIcon(item: item, sizeClass: .small, pointSize: 16)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            if tab.renamingItemID == item.url {
                InlineRenameField(initialName: item.name) { newName in
                    tab.commitRename(item.url, to: newName)
                } onCancel: {
                    tab.cancelRename()
                }
            } else {
                Text(item.displayName(showingExtensions: showExtensions))
                    .feFont(size: 13)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // macOS Finder tag dots — shown after the filename so the
            // user can see at-a-glance what's been categorised.
            tagDots(for: item)
            // Inline audio preview — renders only for audio files.
            AudioPlayButton(item: item)
            // Trailing spacer extends the row's hit-test area past the
            // end of short filenames so the entire column span counts
            // as a Table row click.
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
        // Per-row drop target + purple hover highlight (folders only).
        // Does NOT interfere with Table row selection — drop is a
        // release-only gesture, click is a tap.
        .folderDropTarget(
            isFolder: FileSystemService.isReadableDirectory(item.url)
        ) { droppedURLs in
            dropInto(item.url, droppedURLs)
        }
    }

    private func dropInto(_ folder: URL, _ dropped: [URL]) -> Bool {
        guard FileSystemService.isReadableDirectory(folder) else { return false }
        let sources = dropped.filter { $0 != folder && $0.deletingLastPathComponent() != folder }
        guard !sources.isEmpty else { return false }
        let mods = NSEvent.modifierFlags
        let mode: TabViewModel.DropMode = mods.contains(.option) ? .copy
            : mods.contains(.command) ? .move : .auto
        tab.transferDropped(sources, to: folder, mode: mode)
        return true
    }

    @ViewBuilder
    private func tagDots(for item: FileItem) -> some View {
        let tags = item.tagNames
        if !tags.isEmpty {
            HStack(spacing: 2) {
                ForEach(tags.prefix(4), id: \.self) { name in
                    Circle()
                        .fill(Color(nsColor: TagService.color(for: name) ?? .systemGray))
                        .frame(width: 7, height: 7)
                        .help(name)
                }
            }
        }
    }

    /// Standalone tags cell for the optional "Tags" column. Renders all
    /// of an item's tags (up to 5) as colour dots; a dash for untagged
    /// items so the column doesn't read as empty rows.
    @ViewBuilder
    private func tagsCell(for item: FileItem) -> some View {
        if item.tagNames.isEmpty {
            Text("—")
                .foregroundStyle(.tertiary)
                .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
        } else {
            HStack(spacing: 3) {
                ForEach(item.tagNames.prefix(5), id: \.self) { name in
                    Circle()
                        .fill(Color(nsColor: TagService.color(for: name) ?? .systemGray))
                        .frame(width: 9, height: 9)
                        .help(name)
                }
            }
            .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for selection: Set<URL>) -> some View {
        if selection.isEmpty {
            newSubmenu
            Divider()
            Button("Paste") { tab.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!clipboard.hasContent)
            Button("Copy Folder Path") {
                ClipboardService.copyPathsToPasteboard([tab.currentURL])
            }
            Button("Open in Terminal") {
                TerminalLauncher.open(tab.currentURL)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([tab.currentURL])
            }
            Divider()
            sortBySubmenu
            viewBySubmenu
            Divider()
            Button("Refresh") { tab.reload() }
            Button("Get Info") {
                NotificationCenter.default.post(name: .feShowProperties, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
        } else {
            Button("Open") { openSelection(selection) }
            // "Open With…" — only meaningful for a single, non-directory
            // selection. macOS reports per-UTI handlers; mixed selections
            // would need intersection logic that doesn't add real value.
            if selection.count == 1, let only = selection.first,
               !FileSystemService.isReadableDirectory(only) {
                openWithFileMenu(for: only, tab: tab)
            }
            Divider()
            Button("Cut")  { clipboard.cut(Array(selection)) }
                .keyboardShortcut("x", modifiers: .command)
            Button("Copy") { clipboard.copy(Array(selection)) }
                .keyboardShortcut("c", modifiers: .command)
            Button("Paste") { tab.paste() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!clipboard.hasContent)
            Button("Copy Path") {
                ClipboardService.copyPathsToPasteboard(Array(selection))
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            Divider()
            Button("Rename") {
                tab.selectedIDs = selection
                tab.beginRenameSelected()
            }
            .disabled(selection.count != 1)
            Button("Move to Trash") {
                tab.selectedIDs = selection
                tab.moveSelectedToTrash()
            }
            // Folder size on demand — only meaningful for directories.
            let folderURLs = Array(selection).filter { FileSystemService.isReadableDirectory($0) }
            if !folderURLs.isEmpty {
                Button("Calculate Size") {
                    Task {
                        for url in folderURLs {
                            await FolderSizeService.shared.calculate(url)
                        }
                        tab.objectWillChange.send()  // refresh visible row
                    }
                }
            }
            // Pin / Unpin — only for single folder selection.
            if selection.count == 1, let only = selection.first,
               FileSystemService.isReadableDirectory(only) {
                Divider()
                if BookmarkService.shared.isPinned(only) {
                    Button("Remove from Pinned") {
                        BookmarkService.shared.unpin(only)
                    }
                } else {
                    Button("Pin to Sidebar") {
                        BookmarkService.shared.pin(only)
                    }
                }
            }
            // Batch rename — only useful with 2+ items selected.
            if selection.count >= 2 {
                Divider()
                Button("Rename \(selection.count) Items…") {
                    tab.selectedIDs = selection
                    NotificationCenter.default.post(name: .feShowBatchRename, object: nil)
                }
            }
            // Restore from Trash — only when ALL selected items live
            // inside the user's Trash folder.
            if selection.allSatisfy({ TrashHelper.isInTrash($0) }) {
                Divider()
                Button("Restore from Trash") {
                    TrashService.restore(Array(selection))
                    tab.reload()
                }
                if selection.count == 1, let only = selection.first {
                    // Reveal the trashed item's original parent in a
                    // new Finder window — handy when the user can't
                    // remember where it came from.
                    Button("Show Original Location") {
                        if let orig = TrashService.originalLocation(of: only) {
                            NSWorkspace.shared.activateFileViewerSelecting([orig])
                        }
                    }
                }
            }
            // Compress / Extract
            Divider()
            Button("Compress to ZIP") {
                tab.selectedIDs = selection
                tab.compressSelection()
            }
            if selection.contains(where: { isExtractable($0) }) {
                Button("Extract Here") {
                    tab.selectedIDs = selection
                    tab.extractSelection()
                }
            }
            // Finder tags — toggling adds or removes the tag on every
            // selected item. A ✓ marks a tag that's already applied to
            // *every* selected item, so the user can see at a glance
            // what they're toggling.
            Menu("Tags") {
                let selectedURLs = Array(selection)
                let commonTags = commonTagNames(across: selectedURLs)
                ForEach(TagService.standardTags, id: \.name) { tag in
                    Button {
                        TagService.toggleTag(tag.name, on: selectedURLs)
                        tab.reload()
                    } label: {
                        if commonTags.contains(tag.name) {
                            Label(tag.name, systemImage: "checkmark")
                                .foregroundStyle(Color(nsColor: tag.color))
                        } else {
                            Label(tag.name, systemImage: "circle.fill")
                                .foregroundStyle(Color(nsColor: tag.color))
                        }
                    }
                }
            }
            Divider()
            // Terminal-aware folder shortcut — only meaningful when
            // exactly one directory is selected.
            if selection.count == 1, let only = selection.first,
               FileSystemService.isReadableDirectory(only) {
                Button("Open in Terminal") {
                    TerminalLauncher.open(only)
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(Array(selection))
            }
            Button("Share…") {
                ShareService.showPicker(for: Array(selection))
            }
        }
    }

    /// Predicate used by the Extract Here menu — keep in sync with
    /// `TabViewModel.extractSelection`'s supported list.
    private func isExtractable(_ url: URL) -> Bool {
        let suffixes = [".zip", ".tar", ".tar.gz", ".tgz",
                        ".tar.bz2", ".tbz", ".tar.xz", ".txz"]
        let name = url.lastPathComponent.lowercased()
        return suffixes.contains { name.hasSuffix($0) }
    }

    /// "Original Location" column body. Reads from the cache; absent
    /// entries show "—" until the AppleScript batch finishes.
    private func originalLocationText(for item: FileItem) -> String {
        guard TrashHelper.isInTrash(item.url) else { return "—" }
        return trashCache.parent(of: item.url)?.path ?? "Loading…"
    }

    /// Tags that are present on every URL in the selection — used to
    /// mark "fully applied" tags in the Tags submenu with a checkmark.
    private func commonTagNames(across urls: [URL]) -> Set<String> {
        guard let first = urls.first else { return [] }
        let initial = Set(TagService.tagNames(of: first))
        return urls.dropFirst().reduce(initial) { acc, url in
            acc.intersection(Set(TagService.tagNames(of: url)))
        }
    }

    /// "New ▶ Folder / Text File" submenu for the blank-area context.
    /// Matches Windows Explorer's right-click → New top-level entry.
    @ViewBuilder
    private var newSubmenu: some View {
        Menu("New") {
            Button("Folder") { tab.createNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Text File") {
                tab.createNewFile(baseName: "New Text File", extension: "txt")
            }
        }
    }

    /// "Sort by ▶" submenu — mirrors the column-header sort but is
    /// reachable from any context that doesn't have a header (Icons /
    /// Compact / Grouped views).
    @ViewBuilder
    private var sortBySubmenu: some View {
        Menu("Sort By") {
            ForEach(FileItem.SortKey.allCases) { key in
                Button {
                    tab.setSort(key)
                } label: {
                    if tab.sortKey == key {
                        Label(key.rawValue,
                              systemImage: tab.sortAscending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(key.rawValue)
                    }
                }
            }
        }
    }

    /// "View ▶" submenu mirrors the View menu's three modes, callable
    /// without leaving the context menu.
    @ViewBuilder
    private var viewBySubmenu: some View {
        Menu("View") {
            ForEach(FileViewMode.allCases) { mode in
                Button {
                    NotificationCenter.default.post(
                        name: .feSetViewMode, object: nil,
                        userInfo: ["mode": mode.rawValue]
                    )
                } label: {
                    Label(mode.displayName, systemImage: mode.symbol)
                }
            }
        }
    }

    // MARK: - Sort / Open

    private var sortOrderBinding: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            // Reflecting the current sort state on `get` is what lets
            // the user toggle ascending ↔ descending. The previous
            // implementation returned `[]` every read, so SwiftUI.Table
            // treated every header click as the first one and the
            // second click did nothing.
            get: {
                let order: SortOrder = tab.sortAscending ? .forward : .reverse
                let comparator: KeyPathComparator<FileItem>
                switch tab.sortKey {
                case .name:
                    comparator = KeyPathComparator(\FileItem.name, order: order)
                case .typeLabel:
                    comparator = KeyPathComparator(\FileItem.typeLabel, order: order)
                case .dateLastOpened:
                    comparator = KeyPathComparator(\FileItem.dateAccessedSortableString, order: order)
                case .dateModified:
                    comparator = KeyPathComparator(\FileItem.dateSortableString, order: order)
                case .dateCreated:
                    comparator = KeyPathComparator(\FileItem.dateCreatedSortableString, order: order)
                case .size:
                    comparator = KeyPathComparator(\FileItem.sizeSortableInt, order: order)
                case .tags:
                    comparator = KeyPathComparator(\FileItem.tagsSortable, order: order)
                }
                return [comparator]
            },
            set: { newOrder in
                guard let comp = newOrder.first else { return }
                let ascending = (comp.order == .forward)
                if comp.keyPath == \FileItem.name { tab.sortKey = .name }
                else if comp.keyPath == \FileItem.typeLabel { tab.sortKey = .typeLabel }
                else if comp.keyPath == \FileItem.dateAccessedSortableString { tab.sortKey = .dateLastOpened }
                else if comp.keyPath == \FileItem.dateSortableString { tab.sortKey = .dateModified }
                else if comp.keyPath == \FileItem.dateCreatedSortableString { tab.sortKey = .dateCreated }
                else if comp.keyPath == \FileItem.sizeSortableInt { tab.sortKey = .size }
                else if comp.keyPath == \FileItem.tagsSortable { tab.sortKey = .tags }
                tab.sortAscending = ascending
                tab.reload()
            }
        )
    }

    private func openSelection(_ urls: Set<URL>) {
        // SwiftUI Table's primaryAction passes whatever it considers the
        // active selection, which should match tab.selectedIDs. Sync
        // before delegating so a row that was right-click-opened (and
        // not multi-selected first) still gets handled.
        if tab.selectedIDs != urls {
            tab.selectedIDs = urls
        }
        tab.openSelected()
    }

    // MARK: - Column persistence

    /// Hydrate `columnCustomization` from its @AppStorage backing on
    /// first appearance. Silently ignores decode failures — a corrupt
    /// blob just resets to defaults instead of crashing.
    private func restoreColumnCustomization() {
        guard !columnCustomizationData.isEmpty,
              let decoded = try? JSONDecoder().decode(
                TableColumnCustomization<FileItem>.self,
                from: columnCustomizationData
              ) else { return }
        columnCustomization = decoded
    }

    private func persistColumnCustomization(_ value: TableColumnCustomization<FileItem>) {
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        columnCustomizationData = encoded
    }

    // MARK: - Formatting

    private func formatDate(_ date: Date?) -> String {
        FileFormatters.short(date)
    }

    private func formatSize(_ item: FileItem) -> String {
        if item.isDirectory && !item.isPackage {
            // Show the cached recursive size if the user has run
            // "Calculate Size" on this folder.
            if let cached = FolderSizeService.shared.cachedSize(of: item.url) {
                return ByteCountFormatter.string(fromByteCount: cached, countStyle: .file)
            }
            return "—"
        }
        guard let bytes = item.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Sortable derived strings/ints

extension FileItem {
    var dateSortableString: String {
        guard let d = dateModified else { return "" }
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    var dateCreatedSortableString: String {
        guard let d = dateCreated else { return "" }
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    var dateAccessedSortableString: String {
        guard let d = dateAccessed else { return "" }
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    var sizeSortableInt: Int64 {
        size ?? -1
    }

    /// File extension without the leading dot. Empty for folders and
    /// extension-less files — KeyPath sort comparators need a stable
    /// value so we don't return nil.
    var fileExtension: String {
        (name as NSString).pathExtension
    }

    /// Joined tag list for column sorting. Order-insensitive (we sort
    /// the names first) so two items with the same tags but different
    /// add-order compare equal.
    var tagsSortable: String {
        tagNames.sorted().joined(separator: ",")
    }

    /// Parent directory path — surfaced as an optional Details column
    /// so the user can see where Spotlight results came from.
    var parentPath: String {
        url.deletingLastPathComponent().path
    }
}


// MARK: - Table slow-click → rename detector

/// Detects a Finder-style "click an already-selected row → rename" on
/// the SwiftUI `Table`, which exposes no per-row click callback.
///
/// PASSIVE: its local monitors always return the event unchanged, so
/// native selection and double-click are untouched. Detection (proven)
/// is on mouseDown via a before/after selection comparison; a DRAG is
/// filtered two ways so moving a selected row never renames:
///   • on mouseUp, if the cursor travelled far → cancel the armed rename
///   • when the rename fires, if a mouse button is still down (dragging
///     in progress) → skip.
@MainActor
final class TableRenameClickDetector {
    private weak var tab: TabViewModel?
    private weak var probe: NSView?
    private var downMonitor: Any?
    private var upMonitor: Any?
    private var renameArm: DispatchWorkItem?
    /// (sole-selected URL, when it became sole). A slow second click
    /// only renames if this is older than the double-click window — a
    /// fast second click keeps it recent, so the Table opens instead.
    private var soleSince: (url: URL, at: Date)?
    /// Timestamp of the previous mouseDown — recognises the second press
    /// of a double-click so it isn't treated as a slow re-click.
    private var lastMouseDownAt: Date = .distantPast
    /// mouseDown location (window coords), to measure travel at mouseUp.
    private var downLocation: CGPoint?

    /// The Table-sized NSView (via `RenameProbeView`) used to scope
    /// clicks to the list — a toolbar click while a row is selected
    /// must not arm a rename.
    func setProbe(_ view: NSView) { probe = view }

    func start(tab: TabViewModel) {
        self.tab = tab
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleDown(event) }
            return event
        }
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleUp(event) }
            return event
        }
    }

    func stop() {
        renameArm?.cancel(); renameArm = nil
        if let m = downMonitor { NSEvent.removeMonitor(m); downMonitor = nil }
        if let m = upMonitor { NSEvent.removeMonitor(m); upMonitor = nil }
    }

    /// From the Table's `.onChange(of: selectedIDs)`. Resets the clock
    /// only when the sole selection moves to a different row.
    func selectionChanged(_ sel: Set<URL>) {
        if sel.count == 1, let only = sel.first {
            if soleSince?.url != only { soleSince = (only, Date()) }
        } else {
            soleSince = nil
        }
    }

    func cancelArm() { renameArm?.cancel(); renameArm = nil }

    /// Called when `renamingItemID` changes (rename started/committed).
    /// Cancels any pending arm AND restarts the sole-selection clock:
    /// `commitRename` reselects the just-renamed row, but its URL is
    /// unchanged so `soleSince` would otherwise stay old — letting a
    /// stale timer immediately re-arm a rename on it (the bug where the
    /// selection moves on but the old row stays in edit mode).
    func renameDidChange() {
        renameArm?.cancel(); renameArm = nil
        if let s = soleSince { soleSince = (s.url, Date()) }
    }

    private func handleDown(_ event: NSEvent) {
        // Only track presses in THIS window (local monitors see all
        // windows) so a click elsewhere can't pollute the drag test.
        guard let probe, event.window == probe.window else { return }
        downLocation = event.locationInWindow
        guard let tab, tab.renamingItemID == nil else { return }
        guard event.modifierFlags.isDisjoint(with: [.shift, .command, .option, .control]),
              clickInsideTable(event) else { return }
        // Second press of a double-click → skip, so it opens cleanly.
        let now = Date()
        let isDoubleClickSecond = now.timeIntervalSince(lastMouseDownAt) < NSEvent.doubleClickInterval
        lastMouseDownAt = now
        if isDoubleClickSecond { return }
        // Captured before the Table changes selection on mouseDown.
        let before = tab.selectedIDs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let tab = self.tab else { return }
            let after = tab.selectedIDs
            guard tab.renamingItemID == nil,
                  before == after,                       // click didn't change selection
                  after.count == 1, let only = after.first,
                  let sole = self.soleSince, sole.url == only,
                  Date().timeIntervalSince(sole.at) > NSEvent.doubleClickInterval
            else { return }
            self.renameArm?.cancel()
            let work = DispatchWorkItem {
                guard tab.selectedIDs == [only], tab.renamingItemID == nil else { return }
                // Don't rename mid-drag (a button is still held) or when
                // the click was really on the row's audio ▶ control.
                guard NSEvent.pressedMouseButtons == 0,
                      !AudioPreviewService.shared.recentlyToggled(only) else { return }
                tab.renamingItemID = only
            }
            self.renameArm = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NSEvent.doubleClickInterval + 0.1, execute: work)
        }
    }

    private func handleUp(_ event: NSEvent) {
        defer { downLocation = nil }
        // Local monitors fire for EVERY window of the app — ignore mouse
        // events in another window, or a drag there would cancel THIS
        // window's armed rename.
        guard let probe, event.window == probe.window else { return }
        // If the cursor travelled far between down and up, this was a
        // drag (move a selected row) → cancel any rename armed on down.
        guard let down = downLocation else { return }
        let dx = event.locationInWindow.x - down.x
        let dy = event.locationInWindow.y - down.y
        if dx * dx + dy * dy > 25 {   // > 5pt
            renameArm?.cancel(); renameArm = nil
        }
    }

    private func clickInsideTable(_ event: NSEvent) -> Bool {
        guard let probe, let win = event.window, probe.window == win else { return false }
        let p = probe.convert(event.locationInWindow, from: nil)
        return probe.bounds.contains(p)
    }
}

/// Transparent NSView planted as the Table's `.background`, mirroring
/// its frame so the detector can hit-test clicks against the list.
private struct RenameProbeView: NSViewRepresentable {
    let onView: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onView(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Background drop catcher (AppKit)

/// AppKit drop target for the Table's BACKGROUND. Registered for file
/// URLs and planted behind the Table: AppKit routes a drag to the
/// deepest REGISTERED view under the cursor, so folder-row cells (their
/// SwiftUI drop targets live in cell hosting views above this) keep
/// winning, and everything else — empty area, file rows, non-name
/// columns — lands here and drops into the pane's current folder,
/// exactly like Finder. The drag-over cursor mirrors the transfer
/// semantics: same-volume = move (no badge), cross-volume or ⌥ = copy
/// (+ badge).
final class TableDropCatcherView: NSView {
    /// Both closures are invoked on the main thread (AppKit drag
    /// callbacks); they hop into MainActor state via assumeIsolated.
    var resolveDestination: () -> URL? = { nil }
    var performDrop: ([URL]) -> Bool = { _ in false }

    /// Per-drag-session cache so `draggingUpdated` (fired continuously
    /// while hovering) doesn't re-read the pasteboard and volume keys
    /// on every tick.
    private var sessionSources: [URL] = []
    private var sessionCrossVolume = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func readURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dest = resolveDestination() else { return [] }
        // Items already in this folder can't be "moved here" — with
        // nothing else in the drag, refuse (not-allowed cursor).
        sessionSources = readURLs(sender).filter {
            $0.deletingLastPathComponent() != dest
        }
        let destVol = (try? dest.resourceValues(forKeys: [.volumeURLKey]))?.volume
        sessionCrossVolume = sessionSources.contains {
            (try? $0.resourceValues(forKeys: [.volumeURLKey]))?.volume != destVol
        }
        return currentOperation()
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        currentOperation()
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        sessionSources = []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { sessionSources = [] }
        guard !sessionSources.isEmpty else { return false }
        return performDrop(sessionSources)
    }

    private func currentOperation() -> NSDragOperation {
        guard !sessionSources.isEmpty else { return [] }
        let mods = NSEvent.modifierFlags
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .generic }
        return sessionCrossVolume ? .copy : .generic
    }
}

/// Bridges TableDropCatcherView into SwiftUI and keeps its closures
/// pointed at the CURRENT tab (the left pane swaps TabViewModel
/// instances when the user changes tabs).
private struct TableDropCatcher: NSViewRepresentable {
    let tab: TabViewModel

    func makeNSView(context: Context) -> TableDropCatcherView {
        let v = TableDropCatcherView()
        wire(v)
        return v
    }

    func updateNSView(_ nsView: TableDropCatcherView, context: Context) {
        wire(nsView)
    }

    private func wire(_ v: TableDropCatcherView) {
        let tab = self.tab
        v.resolveDestination = {
            MainActor.assumeIsolated { tab.currentURL }
        }
        v.performDrop = { sources in
            MainActor.assumeIsolated {
                let mods = NSEvent.modifierFlags
                let mode: TabViewModel.DropMode = mods.contains(.option) ? .copy
                    : mods.contains(.command) ? .move : .auto
                tab.transferDropped(sources, to: tab.currentURL, mode: mode)
                return true
            }
        }
    }
}
