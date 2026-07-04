//
//  SidebarView.swift
//  FileExplorer
//
//  Left navigation pane. Section names follow Finder's convention so
//  the structure feels native to macOS users:
//   • Favorites — user-curated folders (drag-drop here to add)
//   • Quick Access — Desktop / Documents / Downloads / etc.
//   • iCloud — iCloud Drive when enabled
//   • Locations — Macintosh HD + mounted volumes, expandable tree
//   • Recent — most-recently visited folders
//   • Tags — Finder's standard colour tags
//   • Trash
//

import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var bookmarks = BookmarkService.shared
    @StateObject private var rootStore = SidebarRootStore()

    var body: some View {
        List {
            pinnedSection
            quickAccessSection
            iCloudSection
            thisMacSection
            recentSection
            tagsSection
            trashSection
        }
        .listStyle(.sidebar)
    }

    // MARK: iCloud Drive

    /// `~/Library/Mobile Documents/com~apple~CloudDocs` is the on-disk
    /// home of iCloud Drive. Shows only when the user has iCloud Drive
    /// enabled (the folder won't exist otherwise).
    @ViewBuilder
    private var iCloudSection: some View {
        if let iCloudURL = Self.iCloudDriveURL() {
            Section("iCloud") {
                SidebarItem(
                    url: iCloudURL,
                    displayName: "iCloud Drive",
                    symbol: "icloud",
                    symbolColor: .accentColor,
                    tab: tab
                )
            }
        }
    }

    /// Returns iCloud Drive's filesystem URL, or nil if the user has
    /// it disabled. Falls back through Apple's CloudDocs convention.
    private static func iCloudDriveURL() -> URL? {
        let candidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileSystemService.isReadableDirectory(candidate) ? candidate : nil
    }

    // MARK: Favorites (drop-target)

    @ViewBuilder
    private var pinnedSection: some View {
        Section("Favorites") {
            if bookmarks.pinned.isEmpty {
                Text("Drag a folder here to add it")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(bookmarks.pinned, id: \.self) { url in
                    SidebarItem(
                        url: url,
                        displayName: url.lastPathComponent,
                        symbol: "folder.fill",
                        symbolColor: .accentColor,
                        tab: tab
                    )
                    // Per-pinned-item drop target — accepts a drag from
                    // another pinned row to reorder. Drags of files that
                    // aren't yet pinned fall through to the section's
                    // outer .dropDestination, which pins them.
                    .dropDestination(for: URL.self) { droppedURLs, _ in
                        guard let source = droppedURLs.first,
                              bookmarks.isPinned(source),
                              let from = bookmarks.pinned.firstIndex(of: source),
                              let to = bookmarks.pinned.firstIndex(of: url),
                              from != to
                        else { return false }
                        bookmarks.reorder(from: from, to: to)
                        return true
                    }
                    // Outer .contextMenu replaces SidebarItem's inner
                    // one, so re-add Copy Path here.
                    .contextMenu {
                        Button("Copy Path") {
                            ClipboardService.copyPathsToPasteboard([url])
                        }
                        Button("Open in Terminal") {
                            TerminalLauncher.open(url)
                        }
                        Divider()
                        Button("Remove from Favorites") { bookmarks.unpin(url) }
                    }
                }
            }
        }
        // Accept any folder URL dragged here → pin it.
        .dropDestination(for: URL.self) { droppedURLs, _ in
            var pinned = false
            for url in droppedURLs where FileSystemService.isReadableDirectory(url) {
                bookmarks.pin(url)
                pinned = true
            }
            return pinned
        }
    }

    // MARK: Quick Access

    @ViewBuilder
    private var quickAccessSection: some View {
        Section("Quick Access") {
            ForEach(QuickAccess.all, id: \.self) { item in
                SidebarItem(
                    url: item.url,
                    displayName: item.displayName,
                    symbol: item.symbol,
                    symbolColor: .accentColor,
                    tab: tab
                )
            }
        }
    }

    // MARK: Locations

    @ViewBuilder
    private var thisMacSection: some View {
        Section("Locations") {
            ForEach(rootStore.macRoots) { node in
                SidebarFolderRow(node: node, tab: tab, depth: 0)
            }
        }
    }

    // MARK: Tags

    /// Finder's 7 standard colour tags. Clicking one switches the
    /// active tab into a system-wide Spotlight search for that tag —
    /// closest practical mapping since we don't maintain our own
    /// per-tag index.
    @ViewBuilder
    private var tagsSection: some View {
        Section("Tags") {
            ForEach(TagService.standardTags, id: \.name) { tag in
                Button {
                    tab.searchByTag(tag.name)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: tag.color))
                            .frame(width: 9, height: 9)
                        Text(tag.name)
                            .feFont(size: 13)
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Recent

    @ViewBuilder
    private var recentSection: some View {
        if !bookmarks.recents.isEmpty {
            // Sidebar only renders the top 12 to keep the column from
            // becoming a wall — the underlying store retains 50, the
            // rest are reachable when needed.
            Section {
                ForEach(bookmarks.recents.prefix(12), id: \.self) { url in
                    SidebarItem(
                        url: url,
                        displayName: url.lastPathComponent,
                        symbol: "clock",
                        symbolColor: .secondary,
                        tab: tab
                    )
                }
                Button("Clear Recent") { bookmarks.clearRecents() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                }
            }
        }
    }

    // MARK: Trash

    @ViewBuilder
    private var trashSection: some View {
        Section {
            SidebarItem(
                url: rootStore.trashURL,
                displayName: "Trash",
                symbol: "trash",
                symbolColor: .secondary,
                tab: tab
            )
            .contextMenu {
                Button("Copy Path") {
                    ClipboardService.copyPathsToPasteboard([rootStore.trashURL])
                }
                Button("Open in Terminal") {
                    TerminalLauncher.open(rootStore.trashURL)
                }
                Divider()
                Button("Empty Trash…", role: .destructive) {
                    TrashService.emptyTrash()
                    tab.reload()
                }
            }
        }
    }
}

// MARK: - Reusable single-row item

private struct SidebarItem: View {
    let url: URL
    let displayName: String
    let symbol: String
    let symbolColor: Color
    @ObservedObject var tab: TabViewModel

    var body: some View {
        Button { tab.navigate(to: url) } label: {
            Label {
                Text(displayName)
                    .feFont(size: 13)
                    .foregroundStyle(tab.currentURL == url ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(symbolColor)
            }
        }
        .buttonStyle(.plain)
        // Drop target: dragging files onto a sidebar location moves/copies.
        .dropDestination(for: URL.self) { droppedURLs, _ in
            let sources = droppedURLs.filter { $0.deletingLastPathComponent() != url }
            guard !sources.isEmpty,
                  FileSystemService.isReadableDirectory(url) else { return false }
            let mods = NSEvent.modifierFlags
            let mode: TabViewModel.DropMode = mods.contains(.option) ? .copy
                : mods.contains(.command) ? .move : .auto
            tab.transferDropped(sources, to: url, mode: mode)
            return true
        }
        // Baseline context menu — callers (Pinned / Trash sections)
        // can layer additional items via their own .contextMenu, which
        // SwiftUI merges.
        .contextMenu {
            Button("Copy Path") {
                ClipboardService.copyPathsToPasteboard([url])
            }
            if FileSystemService.isReadableDirectory(url) {
                Button("Open in Terminal") {
                    TerminalLauncher.open(url)
                }
            }
        }
    }
}

// MARK: - Lazy recursive tree row (folder hierarchy under "This Mac")

private struct SidebarFolderRow: View {
    @ObservedObject var node: FolderNode
    @ObservedObject var tab: TabViewModel
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button {
                    node.toggleExpanded()
                } label: {
                    Group {
                        if node.isLoading {
                            // Small inline spinner so the user knows the
                            // chevron click registered even when the
                            // directory takes a moment to enumerate.
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .scaleEffect(0.55)
                        } else {
                            Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                                .feFont(size: 9, weight: .bold)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 12)
                }
                .buttonStyle(.plain)

                Button {
                    tab.navigate(to: node.url)
                } label: {
                    Label(node.displayName, systemImage: node.symbol)
                        .feFont(size: 13)
                        .foregroundStyle(tab.currentURL == node.url ? Color.accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { droppedURLs, _ in
                    let sources = droppedURLs.filter { $0.deletingLastPathComponent() != node.url }
                    guard !sources.isEmpty else { return false }
                    let mods = NSEvent.modifierFlags
                    let mode: TabViewModel.DropMode = mods.contains(.option) ? .copy
                        : mods.contains(.command) ? .move : .auto
                    tab.transferDropped(sources, to: node.url, mode: mode)
                    return true
                }
                .contextMenu {
                    Button("Copy Path") {
                        ClipboardService.copyPathsToPasteboard([node.url])
                    }
                    Button("Open in Terminal") {
                        TerminalLauncher.open(node.url)
                    }
                    Divider()
                    // Reflect the current pinned state so the menu is
                    // actionable in both directions — Finder shows
                    // either "Add to Sidebar" or "Remove from Sidebar"
                    // depending on the folder's status.
                    if BookmarkService.shared.isPinned(node.url) {
                        Button("Remove from Favorites") {
                            BookmarkService.shared.unpin(node.url)
                        }
                    } else {
                        Button("Pin to Sidebar") {
                            BookmarkService.shared.pin(node.url)
                        }
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 12)

            if node.isExpanded, let kids = node.children {
                ForEach(kids) { child in
                    SidebarFolderRow(node: child, tab: tab, depth: depth + 1)
                }
            }
        }
    }
}

// MARK: - Root nodes store

@MainActor
private final class SidebarRootStore: ObservableObject {
    @Published private(set) var macRoots: [FolderNode] = []
    let trashURL: URL

    private var mountObservers: [NSObjectProtocol] = []

    init() {
        let fm = FileManager.default
        self.trashURL = (try? fm.url(for: .trashDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

        rebuildRoots()

        // NSWorkspace fires mount/unmount events on its own notification
        // centre (NOT NotificationCenter.default). Without this the
        // sidebar froze on the volume list captured at app launch.
        let center = NSWorkspace.shared.notificationCenter
        let didMount = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildRoots() }
        }
        let didUnmount = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildRoots() }
        }
        self.mountObservers = [didMount, didUnmount]
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.forEach { center.removeObserver($0) }
    }

    private func rebuildRoots() {
        let fm = FileManager.default
        var roots: [FolderNode] = [
            FolderNode(url: URL(fileURLWithPath: "/"),
                       displayName: "Macintosh HD",
                       symbol: "internaldrive")
        ]
        // Volumes returned by `mountedVolumeURLs` include APFS system
        // volumes (Preboot / VM / Update / xarts / iSCPreboot / Hardware),
        // autofs mounts (/System/Volumes/Data/home), and iOS simulator
        // runtimes the user never asked to see. We filter to match
        // Finder: only "browsable" volumes that aren't the root
        // filesystem (which we already added as Macintosh HD) and
        // aren't internal/simulator mounts.
        let keys: [URLResourceKey] = [
            .volumeIsRootFileSystemKey,
            .volumeIsBrowsableKey,
            .volumeIsInternalKey
        ]
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        for vol in mounted {
            let values = try? vol.resourceValues(forKeys: Set(keys))
            // Skip root — already represented as "Macintosh HD".
            if values?.volumeIsRootFileSystem ?? false { continue }
            // Finder's "is this user-facing?" flag. False for APFS
            // system containers (Preboot, VM, Update, xarts, ...).
            guard values?.volumeIsBrowsable ?? false else { continue }
            // Belt-and-braces: drop anything mounted under the system
            // sandbox prefixes even if Browsable lied. Catches the
            // iOS-simulator runtime volumes (iOS_22D8075, etc.) that
            // Xcode mounts opaquely.
            let path = vol.path
            if path.hasPrefix("/System/Volumes/") { continue }
            if path.hasPrefix("/Library/Developer/CoreSimulator/") { continue }
            roots.append(FolderNode(url: vol, symbol: "externaldrive"))
        }
        self.macRoots = roots
    }
}

// MARK: - Quick Access defaults

private struct QuickAccess: Hashable {
    let displayName: String
    let symbol: String
    let url: URL

    static var all: [QuickAccess] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            .init(displayName: home.lastPathComponent, symbol: "house", url: home),
            .init(displayName: "Desktop",   symbol: "menubar.dock.rectangle",
                  url: home.appendingPathComponent("Desktop")),
            .init(displayName: "Documents", symbol: "doc",
                  url: home.appendingPathComponent("Documents")),
            .init(displayName: "Downloads", symbol: "arrow.down.circle",
                  url: home.appendingPathComponent("Downloads")),
            .init(displayName: "Pictures",  symbol: "photo",
                  url: home.appendingPathComponent("Pictures")),
            .init(displayName: "Music",     symbol: "music.note",
                  url: home.appendingPathComponent("Music")),
            .init(displayName: "Movies",    symbol: "film",
                  url: home.appendingPathComponent("Movies")),
        ]
    }
}
