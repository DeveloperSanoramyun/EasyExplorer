//
//  GroupedListView.swift
//  FileExplorer
//
//  Renders the file list with collapsible section headers when the user
//  has picked a Group-by key (Type / Date / Size). When grouping is
//  active this replaces the flat Table/Grid/List — column sort still
//  works inside each section.
//
//  Uses LazyVStack with custom rows (not `List`) so the same marquee
//  selection that the other views support works here too. Section
//  headers are interspersed inside the same LazyVStack — the lasso
//  ignores them naturally because we only report row frames, not
//  header frames, to the preference key.
//
//  The lasso gesture, drop-mode/drop-into logic, and context menus are
//  shared with CompactListView/IconsGridView via RowInteraction.swift —
//  see that file for the shared implementations.
//

import SwiftUI
import AppKit

struct GroupedListView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var clipboard = ClipboardService.shared
    @AppStorage("fe.showExtensions") private var showExtensions: Bool = true
    @State private var collapsedBuckets: Set<String> = []

    // Lasso state — see RowInteraction.swift's `lassoSelectionGesture`.
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var lassoRect: CGRect? = nil
    @State private var baseSelection: Set<URL> = []
    @State private var lastAutoScroll: Date = .distantPast
    @State private var slowRename = SlowClickRename()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(tab.groupedItems, id: \.bucket) { group in
                            Section {
                                if !collapsedBuckets.contains(group.bucket) {
                                    ForEach(group.items) { item in
                                        row(for: item)
                                            .id(item.url)
                                            .background(lassoFrameReporter(for: item.url))
                                            // Multi-selection-aware drag
                                            // source — see beginRowDrag.
                                            .onDrag { beginRowDrag(item.url, tab: tab) }
                                            .folderDropTarget(
                                                isFolder: FileSystemService.isReadableDirectory(item.url)
                                            ) { droppedURLs in
                                                fileListDropInto(item.url, dropped: droppedURLs, tab: tab)
                                            }
                                    }
                                }
                            } header: {
                                sectionHeader(for: group)
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
                        flatItems: tab.groupedItems.flatMap(\.items),
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
                    Menu("Group By") {
                        ForEach(GroupKey.allCases) { key in
                            Button(key.displayName) { tab.groupBy = key }
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

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(for group: (bucket: String, items: [FileItem])) -> some View {
        Button {
            if collapsedBuckets.contains(group.bucket) {
                collapsedBuckets.remove(group.bucket)
            } else {
                collapsedBuckets.insert(group.bucket)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedBuckets.contains(group.bucket)
                                  ? "chevron.right" : "chevron.down")
                    .feFont(size: 9, weight: .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(group.bucket)
                    .font(.subheadline.weight(.semibold))
                Text("(\(group.items.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for item: FileItem) -> some View {
        let isSelected = tab.selectedIDs.contains(item.url)
        HStack(spacing: 8) {
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
                    .allowsHitTesting(false)
            }
            // Tag dots
            let tags = item.tagNames
            if !tags.isEmpty {
                HStack(spacing: 2) {
                    ForEach(tags.prefix(4), id: \.self) { name in
                        Circle()
                            .fill(Color(nsColor: TagService.color(for: name) ?? .systemGray))
                            .frame(width: 7, height: 7)
                    }
                }
                .allowsHitTesting(false)
            }
            AudioPlayButton(item: item)
            Spacer()
            Text(formatDate(item.dateModified))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 130, alignment: .trailing)
                .allowsHitTesting(false)
            Text(formatSize(item))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
                .allowsHitTesting(false)
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

    // MARK: - Formatting

    private func formatDate(_ date: Date?) -> String {
        FileFormatters.short(date)
    }

    private func formatSize(_ item: FileItem) -> String {
        if item.isDirectory && !item.isPackage { return "" }
        guard let bytes = item.size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
