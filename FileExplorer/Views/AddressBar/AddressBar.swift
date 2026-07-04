//
//  AddressBar.swift
//  FileExplorer
//
//  Top breadcrumb + back/forward/up + search. Clicking an empty area of
//  the breadcrumb (or pressing ⌘L) flips it into edit mode — the user
//  types a path directly. Enter navigates, Esc cancels.
//

import SwiftUI

struct AddressBar: View {
    @ObservedObject var tab: TabViewModel

    /// Edit-mode state lives here so toggling between breadcrumb and
    /// TextField is local. The path string is initialised every time we
    /// enter edit mode so the user sees the current location.
    @State private var isEditing: Bool = false
    @State private var editingPath: String = ""
    @FocusState private var editFocused: Bool
    @FocusState private var searchFocused: Bool

    /// Tab-completion cycle state. When the user presses Tab and the
    /// current prefix matches multiple folders, we drop them into the
    /// field one-by-one; another Tab advances to the next match.
    /// `snapshot` is the text we wrote on the last cycle step — if the
    /// user types anything in between, it diverges from `editingPath`
    /// and we reset.
    @State private var cycleMatches: [String] = []
    @State private var cycleIndex: Int = 0
    @State private var cycleParent: String = ""
    @State private var cycleSnapshot: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            navButtons
            Divider().frame(height: 16)
            Group {
                if isEditing {
                    pathTextField
                } else {
                    breadcrumb
                }
            }
            Spacer(minLength: 12)
            // Search field stays in the AddressBar row — SwiftUI's
            // window-toolbar layer on macOS swallows keyboard focus
            // for nested TextFields, so the field renders but won't
            // actually type. The view-mode picker is fine in the
            // toolbar (just buttons, no input).
            searchField
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        // ⌘L = jump to address bar (Windows: Ctrl+L / Alt+D / F4)
        .onReceive(NotificationCenter.default.publisher(for: .feFocusAddressBar)) { _ in
            beginEditing()
        }
    }

    // MARK: - Search (inline in the AddressBar row)

    private var searchField: some View {
        HStack(spacing: 4) {
            Button {
                tab.searchScope = (tab.searchScope == .folder) ? .thisMac : .folder
            } label: {
                Image(systemName: tab.searchScope == .thisMac
                                  ? "magnifyingglass.circle.fill"
                                  : "magnifyingglass")
                    .foregroundStyle(tab.searchScope == .thisMac
                                     ? Color.accentColor : Color.secondary)
                    .feFont(size: 12)
            }
            .buttonStyle(.borderless)
            .help(tab.searchScope == .thisMac
                  ? "Searching all of This Mac — click to limit to current folder"
                  : "Searching current folder — click to search This Mac")

            TextField(searchPlaceholder, text: $tab.searchQuery)
                .textFieldStyle(.plain)
                .feFont(size: 12)
                .frame(width: 220)
                .focused($searchFocused)
                .onExitCommand { tab.resetSearch() }
            if let spotlight = tab.spotlightService, spotlight.isSearching {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.45)
                    .frame(width: 12, height: 12)
            }
            if !tab.searchQuery.isEmpty {
                Button {
                    tab.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .feFont(size: 11)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(tab.searchScope == .thisMac
                        ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        )
        .onReceive(NotificationCenter.default.publisher(for: .feFocusSearchGlobal)) { _ in
            tab.switchToGlobalSearch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feFocusSearchFolder)) { _ in
            if tab.searchScope != .folder { tab.searchScope = .folder }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    private var searchPlaceholder: String {
        switch tab.searchScope {
        case .folder:  return "Search \(tab.currentURL.lastPathComponent)"
        case .thisMac: return "Search This Mac"
        }
    }

    // MARK: - Navigation buttons

    private var navButtons: some View {
        HStack(spacing: 2) {
            // Back: click goes one step, long-press / right-click opens
            // the history menu. SwiftUI's `Menu` with `primaryAction:`
            // is the macOS-native pattern (Safari, Finder do the same)
            // and avoids the standalone chevron-dropdown next to the
            // arrow that looked like a duplicate button.
            Menu {
                ForEach(Array(tab.backHistory.reversed().enumerated()), id: \.offset) { _, url in
                    Button {
                        tab.goBack(to: url)
                    } label: {
                        Label(historyLabel(for: url), systemImage: "folder")
                    }
                }
            } label: {
                Image(systemName: "chevron.left")
            } primaryAction: {
                tab.goBack()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!tab.canGoBack)
            .help("Back (⌘[) — long-press for history")

            // Forward — symmetrical with back.
            Menu {
                ForEach(Array(tab.forwardHistory.reversed().enumerated()), id: \.offset) { _, url in
                    Button {
                        tab.goForward(to: url)
                    } label: {
                        Label(historyLabel(for: url), systemImage: "folder")
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
            } primaryAction: {
                tab.goForward()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!tab.canGoForward)
            .help("Forward (⌘]) — long-press for history")

            Button { tab.goUp() } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!tab.canGoUp)
            .help("Up (⌘↑)")

            Button { tab.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh (⌘R)")
        }
        .feFont(size: 13, weight: .medium)
    }

    /// Pretty name for a history entry. Includes the parent in brackets
    /// when the last component alone would be ambiguous (two different
    /// "Downloads" folders shouldn't look identical in the dropdown).
    /// Falls back to the full path for unnamed URLs.
    private func historyLabel(for url: URL) -> String {
        if url.path == "/" { return "Macintosh HD" }
        if url.path == NSHomeDirectory() { return "Home" }
        let last = url.lastPathComponent
        guard !last.isEmpty else { return url.path }
        let parent = url.deletingLastPathComponent().lastPathComponent
        // Suppress redundant parent labels for top-level items where the
        // parent is "/" or "Users" — those add noise without context.
        if parent.isEmpty || parent == "/" || parent == "Users" {
            return last
        }
        return "\(last) — \(parent)"
    }

    // MARK: - Breadcrumb

    private var breadcrumb: some View {
        let segments = pathSegments(for: tab.currentURL)
        return HStack(spacing: 0) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
                .feFont(size: 11)
            ForEach(Array(segments.enumerated()), id: \.offset) { idx, segment in
                // For [Mac HD, ...] case the first segment needs a
                // plain visual separator from the icon — there's
                // nothing to its left to enumerate children of.
                if idx == 0 && segment.isRootShortcut {
                    Image(systemName: "chevron.right")
                        .feFont(size: 9, weight: .semibold)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 3)
                }
                Button {
                    tab.navigate(to: segment.url)
                } label: {
                    Text(segment.displayName)
                        .feFont(size: 12)
                        .foregroundStyle(idx == segments.count - 1 ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                // Per-segment right-click — lets the user grab the path
                // at any depth, not just the current folder.
                .contextMenu {
                    Button("Copy Path") {
                        ClipboardService.copyPathsToPasteboard([segment.url])
                    }
                }
                // Children dropdown after each segment — click the ▸ to
                // jump to a sibling/child folder without leaving the
                // breadcrumb (Windows Explorer's signature trick).
                childFoldersMenu(for: segment.url)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        // Clicking the empty area of the breadcrumb pill enters edit
        // mode — Windows Explorer behaviour.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEditing() }
        // Right-clicking the empty pill (not a segment) copies the
        // current folder's path — quick "Copy Folder Path" entry point.
        .contextMenu {
            Button("Copy Folder Path") {
                ClipboardService.copyPathsToPasteboard([tab.currentURL])
            }
            Button("Open in Terminal") {
                TerminalLauncher.open(tab.currentURL)
            }
            Button("Edit Path") { beginEditing() }
        }
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Children dropdown

    /// Tiny ▸ menu rendered next to each breadcrumb segment. Lists the
    /// subfolders of `url` so the user can hop sideways into a sibling.
    /// SwiftUI lazily evaluates Menu content, so the directory listing
    /// only happens on click — not on every breadcrumb redraw.
    @ViewBuilder
    private func childFoldersMenu(for url: URL) -> some View {
        Menu {
            let folders = childFolders(of: url)
            if folders.isEmpty {
                Text("No subfolders").foregroundStyle(.tertiary)
            } else {
                ForEach(folders.prefix(childFoldersLimit), id: \.url) { folder in
                    Button {
                        tab.navigate(to: folder.url)
                    } label: {
                        Label(folder.name, systemImage: "folder")
                    }
                }
                if folders.count > childFoldersLimit {
                    Divider()
                    Text("\(folders.count - childFoldersLimit) more hidden — open the folder to browse all.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } label: {
            Image(systemName: "chevron.right")
                .feFont(size: 9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Hard cap on how many entries the dropdown shows — past 50 the
    /// menu turns into a wall of text and tapping anything becomes
    /// guesswork. The user has the file list itself for the long tail.
    private var childFoldersLimit: Int { 50 }

    private func childFolders(of url: URL) -> [FileItem] {
        // Bail early on non-directories or anything we can't read; the
        // menu just shows "No subfolders" in that case.
        guard FileSystemService.isReadableDirectory(url) else { return [] }
        let listing = (try? FileSystemService.listDirectory(at: url, includeHidden: false)) ?? []
        return listing
            .filter { $0.isDirectory && !$0.isPackage }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Edit-mode text field

    private var pathTextField: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil")
                .feFont(size: 11)
                .foregroundStyle(.secondary)
            TextField("Type a path…", text: $editingPath, onCommit: commitEditing)
                .textFieldStyle(.plain)
                .feFont(size: 12)
                .focused($editFocused)
                .onExitCommand { cancelEditing() }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    // SwiftUI's default Tab handling moves focus; we
                    // override it to do shell-style path completion
                    // instead. Shift-Tab walks the cycle the other way,
                    // matching zsh / bash autocomplete muscle memory.
                    performTabCompletion(reverse: press.modifiers.contains(.shift))
                    return .handled
                }
                .onChange(of: editingPath) { _, newValue in
                    // Any edit that wasn't our own cycle write breaks
                    // out of cycle mode — Tab should start a fresh
                    // match list against the new prefix.
                    if newValue != cycleSnapshot {
                        cycleSnapshot = nil
                    }
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
    }

    private func beginEditing() {
        editingPath = tab.currentURL.path
        isEditing = true
        resetCycle()
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEditing() {
        let trimmed = editingPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { isEditing = false; return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        tab.navigate(to: url)
        isEditing = false
        resetCycle()
    }

    private func cancelEditing() {
        editingPath = ""
        isEditing = false
        resetCycle()
    }

    // MARK: - Tab completion

    /// Try to extend `editingPath` from a partial folder name into the
    /// full one. First Tab finds matching subfolders of the path's
    /// parent and either (a) completes to a unique match, (b) extends
    /// the common prefix, or (c) seeds a cycle through the candidates
    /// — repeated Tabs walk that list in alphabetical order.
    /// `reverse == true` walks the cycle backwards (Shift-Tab).
    private func performTabCompletion(reverse: Bool = false) {
        // Continuing an active cycle? Just advance / retreat.
        if let snap = cycleSnapshot,
           snap == editingPath,
           !cycleMatches.isEmpty {
            let step = reverse ? -1 : 1
            cycleIndex = (cycleIndex + step + cycleMatches.count) % cycleMatches.count
            let next = (cycleParent as NSString).appendingPathComponent(cycleMatches[cycleIndex])
            editingPath = next
            cycleSnapshot = next
            return
        }

        // Fresh completion: split editingPath into parent dir + prefix.
        guard let (parentPath, prefix) = splitForCompletion(editingPath) else {
            return
        }

        let parentURL = URL(fileURLWithPath: parentPath)
        guard FileSystemService.isReadableDirectory(parentURL) else { return }
        let children = (try? FileSystemService.listDirectory(at: parentURL, includeHidden: false)) ?? []
        let matches = children
            .filter { $0.isDirectory && !$0.isPackage }
            .filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.name)

        guard !matches.isEmpty else { return }

        if matches.count == 1 {
            // Single hit — complete + trailing slash so the next key
            // (or next Tab) descends into it.
            let completed = (parentPath as NSString).appendingPathComponent(matches[0]) + "/"
            editingPath = completed
            cycleSnapshot = completed
            return
        }

        let common = longestCommonPrefix(matches)
        if common.count > prefix.count {
            // Stretch the prefix as far as it can unambiguously go.
            let completed = (parentPath as NSString).appendingPathComponent(common)
            editingPath = completed
            cycleSnapshot = completed
            return
        }

        // No progress — start cycling alphabetically.
        cycleParent = parentPath
        cycleMatches = matches
        cycleIndex = 0
        let first = (parentPath as NSString).appendingPathComponent(matches[0])
        editingPath = first
        cycleSnapshot = first
    }

    /// Break `path` into (parent directory, last-component prefix) for
    /// completion. Special-cases `~` and `~/foo` so they're anchored to
    /// the home directory rather than substrings of `/Users`.
    private func splitForCompletion(_ path: String) -> (parent: String, prefix: String)? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" {
            return (NSHomeDirectory(), "")
        }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            if let slash = rest.lastIndex(of: "/") {
                let parentRel = String(rest[..<slash])
                let prefix = String(rest[rest.index(after: slash)...])
                let parent = (NSHomeDirectory() as NSString).appendingPathComponent(parentRel)
                return (parent, prefix)
            }
            return (NSHomeDirectory(), rest)
        }
        let ns = trimmed as NSString
        let lastSlash = ns.range(of: "/", options: .backwards)
        guard lastSlash.location != NSNotFound else { return nil }
        let parent = lastSlash.location == 0 ? "/" : ns.substring(to: lastSlash.location)
        let prefix = ns.substring(from: lastSlash.location + 1)
        return (parent, prefix)
    }

    private func longestCommonPrefix(_ strings: [String]) -> String {
        guard var common = strings.first else { return "" }
        for s in strings.dropFirst() {
            while !s.lowercased().hasPrefix(common.lowercased()) {
                common.removeLast()
                if common.isEmpty { return "" }
            }
        }
        return common
    }

    private func resetCycle() {
        cycleMatches = []
        cycleIndex = 0
        cycleParent = ""
        cycleSnapshot = nil
    }

    // MARK: - Path → segments

    private func pathSegments(for url: URL) -> [BreadcrumbSegment] {
        var result: [BreadcrumbSegment] = []
        var current = url
        while current.path != "/" {
            let isHome = current.path == NSHomeDirectory()
            result.insert(
                BreadcrumbSegment(
                    displayName: isHome ? "Home" : current.lastPathComponent,
                    url: current,
                    isRootShortcut: false
                ),
                at: 0
            )
            if isHome { break }
            current = current.deletingLastPathComponent()
        }
        if result.first?.url.path != NSHomeDirectory() {
            result.insert(
                BreadcrumbSegment(
                    displayName: "Macintosh HD",
                    url: URL(fileURLWithPath: "/"),
                    isRootShortcut: true
                ),
                at: 0
            )
        }
        return result
    }

}

// MARK: - Toolbar components (extracted so they can live in the
// window's NSToolbar via SwiftUI's `.toolbar` modifier instead of
// being baked into the in-content AddressBar row).

/// Four-button view-mode picker for the window toolbar. Highlights
/// the active mode and posts `.feSetViewMode` so per-folder + global
/// preferences stay in sync — same wiring the View menu uses.
struct ToolbarViewModePicker: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject private var folderModes = FolderViewModeService.shared
    @AppStorage("fe.viewMode") private var viewModeRaw: String = FileViewMode.details.rawValue

    private var currentMode: FileViewMode {
        if let folder = folderModes.mode(for: tab.currentURL) {
            return folder
        }
        return FileViewMode(rawValue: viewModeRaw) ?? .details
    }

    var body: some View {
        // ControlGroup is the macOS-native way to cluster a few small
        // toolbar buttons — it draws the unified pill background that
        // matches Finder's view-mode segmented control.
        ControlGroup {
            ForEach(FileViewMode.allCases) { mode in
                Button {
                    NotificationCenter.default.post(
                        name: .feSetViewMode, object: nil,
                        userInfo: ["mode": mode.rawValue]
                    )
                } label: {
                    Image(systemName: mode.symbol)
                        .foregroundStyle(currentMode == mode
                                         ? Color.accentColor
                                         : Color.primary)
                }
                .help(mode.displayName)
            }
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
    }
}

private struct BreadcrumbSegment {
    let displayName: String
    let url: URL
    let isRootShortcut: Bool
}

// MARK: - Notification names (cross-view command bus)

extension Notification.Name {
    static let feFocusAddressBar = Notification.Name("FE.FocusAddressBar")
    static let feGoBack          = Notification.Name("FE.GoBack")
    static let feGoForward       = Notification.Name("FE.GoForward")
    static let feGoUp            = Notification.Name("FE.GoUp")
    static let feReload          = Notification.Name("FE.Reload")
    static let feNewFolder       = Notification.Name("FE.NewFolder")
    // Sprint 3 — Edit menu commands
    static let feCutSelection             = Notification.Name("FE.CutSelection")
    static let feCopySelection            = Notification.Name("FE.CopySelection")
    static let fePaste                    = Notification.Name("FE.Paste")
    static let feMoveSelectionToTrash     = Notification.Name("FE.MoveSelectionToTrash")
    static let feDeleteSelectionPermanently = Notification.Name("FE.DeleteSelectionPermanently")
    static let feRenameSelection          = Notification.Name("FE.RenameSelection")
    static let feCopyPath                 = Notification.Name("FE.CopyPath")
    static let feDuplicateSelection       = Notification.Name("FE.DuplicateSelection")
    static let feSelectAll                = Notification.Name("FE.SelectAll")
    /// ⌘F — focus the folder search box (vs. ⌘⇧F for global).
    static let feFocusSearchFolder        = Notification.Name("FE.FocusSearchFolder")
    static let feToggleSidebar            = Notification.Name("FE.ToggleSidebar")
    /// userInfo["mode"] = FileViewMode.rawValue
    static let feSetViewMode              = Notification.Name("FE.SetViewMode")
    // Sprint 5
    static let feTogglePreview            = Notification.Name("FE.TogglePreview")
    // P1 — Tabs
    static let feNewTab                   = Notification.Name("FE.NewTab")
    static let feCloseTab                 = Notification.Name("FE.CloseTab")
    static let feReopenClosedTab          = Notification.Name("FE.ReopenClosedTab")
    static let feSelectTab                = Notification.Name("FE.SelectTab")
    // P1-6 — Spotlight
    static let feFocusSearchGlobal        = Notification.Name("FE.FocusSearchGlobal")
    // P2-1 — Group by (userInfo["key"] = GroupKey.rawValue)
    static let feSetGroupBy               = Notification.Name("FE.SetGroupBy")
    // P2-4 — Properties (⌘I)
    static let feShowProperties           = Notification.Name("FE.ShowProperties")
    // P2-5 — Batch rename
    static let feShowBatchRename          = Notification.Name("FE.ShowBatchRename")
    // Global text-zoom — ⌘+ / ⌘- / ⌘0
    static let feFontSizeIncrease         = Notification.Name("FE.FontSizeIncrease")
    static let feFontSizeDecrease         = Notification.Name("FE.FontSizeDecrease")
    static let feFontSizeReset            = Notification.Name("FE.FontSizeReset")
    // Undo / Redo — per-tab file-operation history (⌘Z / ⌘⇧Z)
    static let feUndo                     = Notification.Name("FE.Undo")
    static let feRedo                     = Notification.Name("FE.Redo")
    // Onboarding — first-run guide for granting Full Disk Access
    static let feShowPermissionGuide      = Notification.Name("FE.ShowPermissionGuide")
    // Split (dual-pane) view toggle (⌥⌘S)
    static let feToggleSplit              = Notification.Name("FE.ToggleSplit")
}
