//
//  CompactListView.swift
//  FileExplorer
//
//  Windows "List" mode: many items packed into a single tight column,
//  one row per file with just the icon and name. No date / type / size
//  metadata. Good for folders with thousands of items.
//
//  Implementation note: SwiftUI's `List` would be the obvious choice
//  but it intercepts drag gestures for its own selection logic, which
//  blocks marquee (lasso) selection. We render rows manually in a
//  LazyVStack so the same DragGesture-based lasso used by IconsGridView
//  works here too.
//

import SwiftUI
import AppKit

struct CompactListView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var clipboard = ClipboardService.shared
    @AppStorage("fe.showExtensions") private var showExtensions: Bool = true

    // Lasso state — mirrors IconsGridView. See that file for the
    // rationale on PreferenceKey + DragGesture + base-selection
    // capture; the row layout is the only thing that differs.
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var lassoRect: CGRect? = nil
    @State private var baseSelection: Set<URL> = []
    @State private var lastAutoScroll: Date = .distantPast

    /// Pending Finder-style "slow second click → rename" work item.
    /// Scheduled when the user clicks an already-sole-selected row;
    /// cancelled by a double-click, by another row click, or by
    /// navigating away. Keeps a single timer in flight at a time so we
    /// don't accidentally enter rename for the wrong file.
    @State private var slowRename = SlowClickRename()

    /// Move/copy dropped items into `folder` (a directory row). ⌥ forces
    /// copy, ⌘ forces move; otherwise same-volume default applies.
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tab.visibleItems) { item in
                            row(for: item)
                                .id(item.url)
                                .background(frameReporter(for: item.url))
                                // .onDrag (not .draggable) so drag START
                                // can register the multi-selection this
                                // drag stands for — see beginRowDrag.
                                .onDrag { beginRowDrag(item.url, tab: tab) }
                                // Per-row drop target + purple hover
                                // highlight (folders only).
                                .folderDropTarget(
                                    isFolder: FileSystemService.isReadableDirectory(item.url)
                                ) { droppedURLs in
                                    dropInto(item.url, droppedURLs)
                                }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let rect = lassoRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "lasso")
                .gesture(lassoGesture(proxy: proxy))
            }
            .background(.background)
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .onChange(of: tab.currentURL) { _, _ in
                itemFrames.removeAll()
            }
            // Feed the slow-click rename detector — see RowInteraction.
            .onChange(of: tab.selectedIDs) { _, newValue in
                slowRename.selectionChanged(newValue)
            }
            .onChange(of: tab.renamingItemID) { _, _ in
                slowRename.renameDidChange()
            }
            .contextMenu { blankContextMenu }
            .dropDestination(for: URL.self) { droppedURLs, _ in
                let sources = droppedURLs.filter { $0.deletingLastPathComponent() != tab.currentURL }
                guard !sources.isEmpty else { return false }
                let mods = NSEvent.modifierFlags
                let mode: TabViewModel.DropMode = mods.contains(.option) ? .copy
                    : mods.contains(.command) ? .move : .auto
                tab.transferDropped(sources, to: tab.currentURL, mode: mode)
                return true
            }
            .contentShape(Rectangle())
            .onTapGesture { tab.selectedIDs.removeAll() }
            .feKeyboardNavigation(tab: tab)
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let isSelected = tab.selectedIDs.contains(item.url)
        HStack(spacing: 6) {
            ThumbnailIcon(item: item, sizeClass: .small, pointSize: 16)
                .allowsHitTesting(false)
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
                    // Critical: macOS SwiftUI Text views participate in
                    // hit-testing by default (for text selection &
                    // accessibility). That swallows clicks even with
                    // `.contentShape` on the parent. Disabling it makes
                    // the Text pass-through so the row gesture below
                    // catches every click on the filename area.
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
                .allowsHitTesting(false)
            AudioPlayButton(item: item)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .opacity(clipboard.isCutMarked(item.url) ? 0.5 : 1.0)
        .contentShape(Rectangle())
        // count-2 opens; count-1 (simultaneous) selects immediately.
        // Selection / slow-click-rename logic is shared — see
        // RowInteraction.swift.
        .onTapGesture(count: 2) {
            slowRename.noteOpened()
            slowRename.cancel()
            openItem(item)
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                applyRowClick(url: item.url, wasSelected: isSelected,
                              modifiers: currentSelectionModifiers(),
                              tab: tab, slowRename: slowRename)
            }
        )
        .contextMenu { rowContextMenu(for: item.url) }
    }

    // MARK: - Open

    private func openItem(_ item: FileItem) {
        if FileSystemService.isReadableDirectory(item.url) {
            tab.navigate(to: item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Lasso plumbing

    private func frameReporter(for url: URL) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ItemFramePreferenceKey.self,
                value: [url: proxy.frame(in: .named("lasso"))]
            )
        }
    }

    private func lassoGesture(proxy: ScrollViewProxy) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("lasso"))
            .onChanged { value in
                if lassoRect == nil {
                    baseSelection = tab.selectedIDs
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                lassoRect = rect

                var hits: Set<URL> = []
                for (url, frame) in itemFrames where rect.intersects(frame) {
                    hits.insert(url)
                }
                let mods = NSEvent.modifierFlags
                if mods.contains(.command) {
                    tab.selectedIDs = baseSelection.symmetricDifference(hits)
                } else if mods.contains(.shift) {
                    tab.selectedIDs = baseSelection.union(hits)
                } else {
                    tab.selectedIDs = hits
                }
                autoScrollIfNeeded(value: value, proxy: proxy)
            }
            .onEnded { _ in
                lassoRect = nil
                baseSelection = []
            }
    }

    /// See IconsGridView.autoScrollIfNeeded for the rationale — same
    /// throttled "scroll a few rows ahead when the marquee touches
    /// the visible edge" logic.
    private func autoScrollIfNeeded(value: DragGesture.Value, proxy: ScrollViewProxy) {
        guard !itemFrames.isEmpty,
              Date().timeIntervalSince(lastAutoScroll) > 0.08 else { return }
        let edgeZone: CGFloat = 30
        let frames = itemFrames.values
        guard let topY = frames.map(\.minY).min(),
              let bottomY = frames.map(\.maxY).max() else { return }

        if value.location.y < topY + edgeZone {
            if let topItem = itemFrames.min(by: { $0.value.minY < $1.value.minY })?.key,
               let idx = tab.visibleItems.firstIndex(where: { $0.url == topItem }),
               idx > 0 {
                proxy.scrollTo(tab.visibleItems[max(0, idx - 3)].url, anchor: .top)
                lastAutoScroll = Date()
            }
        } else if value.location.y > bottomY - edgeZone {
            if let bottomItem = itemFrames.max(by: { $0.value.maxY < $1.value.maxY })?.key,
               let idx = tab.visibleItems.firstIndex(where: { $0.url == bottomItem }),
               idx < tab.visibleItems.count - 1 {
                proxy.scrollTo(tab.visibleItems[min(tab.visibleItems.count - 1, idx + 3)].url, anchor: .bottom)
                lastAutoScroll = Date()
            }
        }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func rowContextMenu(for url: URL) -> some View {
        Button("Open") {
            if FileSystemService.isReadableDirectory(url) {
                tab.navigate(to: url)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        if !FileSystemService.isReadableDirectory(url) {
            openWithMenu(for: url)
        }
        Divider()
        Button("Cut") {
            ensureSelection(includes: url)
            ClipboardService.shared.cut(Array(tab.selectedIDs))
        }
        Button("Copy") {
            ensureSelection(includes: url)
            ClipboardService.shared.copy(Array(tab.selectedIDs))
        }
        Button("Paste") { tab.paste() }
            .disabled(!ClipboardService.shared.hasContent)
        Button("Copy Path") {
            ensureSelection(includes: url)
            ClipboardService.copyPathsToPasteboard(Array(tab.selectedIDs))
        }
        Divider()
        Button("Move to Trash") {
            ensureSelection(includes: url)
            tab.moveSelectedToTrash()
        }
        Divider()
        Button("Show in Finder") {
            ensureSelection(includes: url)
            NSWorkspace.shared.activateFileViewerSelecting(Array(tab.selectedIDs))
        }
        Button("Share…") {
            ensureSelection(includes: url)
            ShareService.showPicker(for: Array(tab.selectedIDs))
        }
    }

    @ViewBuilder
    private var blankContextMenu: some View {
        Menu("New") {
            Button("Folder") { tab.createNewFolder() }
            Button("Text File") {
                tab.createNewFile(baseName: "New Text File", extension: "txt")
            }
        }
        Divider()
        Button("Paste") { tab.paste() }
            .disabled(!ClipboardService.shared.hasContent)
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
        Menu("Sort By") {
            ForEach(FileItem.SortKey.allCases) { key in
                Button(key.rawValue) { tab.setSort(key) }
            }
        }
        Menu("View") {
            ForEach(FileViewMode.allCases) { mode in
                Button(mode.displayName) {
                    NotificationCenter.default.post(
                        name: .feSetViewMode, object: nil,
                        userInfo: ["mode": mode.rawValue]
                    )
                }
            }
        }
        Divider()
        Button("Refresh") { tab.reload() }
    }

    /// Promote the right-clicked row to selection when it wasn't already
    /// part of the multi-selection — same rule as Finder / Explorer.
    private func ensureSelection(includes url: URL) {
        if !tab.selectedIDs.contains(url) {
            tab.selectedIDs = [url]
        }
    }

    @ViewBuilder
    private func openWithMenu(for url: URL) -> some View {
        Menu("Open With") {
            let apps = AppLauncherService.applications(handlerFor: url)
            ForEach(apps) { app in
                Button {
                    AppLauncherService.open([url], with: app.url)
                } label: {
                    Label {
                        Text(app.isDefault ? "\(app.name) (default)" : app.name)
                    } icon: {
                        Image(nsImage: app.icon)
                    }
                }
            }
            if !apps.isEmpty {
                Divider()
            }
            Button("Other Application…") {
                AppLauncherService.chooseApplication(for: [url])
            }
        }
    }
}
