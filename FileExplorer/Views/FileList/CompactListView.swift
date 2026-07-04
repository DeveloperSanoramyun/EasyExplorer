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
//  The lasso gesture, drop-mode/drop-into logic, and context menus are
//  shared with GroupedListView/IconsGridView via RowInteraction.swift —
//  see that file for the shared implementations.
//

import SwiftUI
import AppKit

struct CompactListView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var clipboard = ClipboardService.shared
    @AppStorage("fe.showExtensions") private var showExtensions: Bool = true

    // Lasso state — mirrors IconsGridView/GroupedListView. See
    // RowInteraction.swift's `lassoSelectionGesture` for the gesture
    // logic these feed into via Binding.
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tab.visibleItems) { item in
                            row(for: item)
                                .id(item.url)
                                .background(lassoFrameReporter(for: item.url))
                                // .onDrag (not .draggable) so drag START
                                // can register the multi-selection this
                                // drag stands for — see beginRowDrag.
                                .onDrag { beginRowDrag(item.url, tab: tab) }
                                // Per-row drop target + purple hover
                                // highlight (folders only).
                                .folderDropTarget(
                                    isFolder: FileSystemService.isReadableDirectory(item.url)
                                ) { droppedURLs in
                                    fileListDropInto(item.url, dropped: droppedURLs, tab: tab)
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
                .gesture(
                    lassoSelectionGesture(
                        itemFrames: itemFrames,
                        lassoRect: $lassoRect,
                        baseSelection: $baseSelection,
                        lastAutoScroll: $lastAutoScroll,
                        flatItems: tab.visibleItems,
                        edgeZone: 30,
                        tab: tab,
                        proxy: proxy
                    )
                )
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
            .contextMenu {
                fileListBlankContextMenu(tab: tab) {
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
                }
            }
            .dropDestination(for: URL.self) { droppedURLs, _ in
                fileListDropIntoCurrentFolder(droppedURLs, tab: tab)
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
            openFileListEntry(item.url, tab: tab)
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                applyRowClick(url: item.url, wasSelected: isSelected,
                              modifiers: currentSelectionModifiers(),
                              tab: tab, slowRename: slowRename)
            }
        )
        .contextMenu { fileListRowContextMenu(for: item.url, tab: tab) }
    }
}
