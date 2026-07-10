//
//  ContentView.swift
//  FileExplorer
//
//  Owns the WindowState (tabs) and forwards every menu/keyboard command
//  to the active tab. Body is intentionally tiny — modifier chain lives
//  in helper structs further down to dodge SwiftUI's type-check timeout.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var window: WindowState
    @StateObject private var clipboard = ClipboardService.shared

    /// `tornOffTabURL` non-nil means this window was just opened by
    /// TabBar's "Move to New Window" (`openWindow(value: url)`) — start
    /// with exactly that one tab instead of restoring the persisted
    /// session, which is what a `nil` value (system "New Window" menu
    /// item, or app launch) still does.
    init(tornOffTabURL: URL? = nil) {
        if let tornOffTabURL {
            _window = StateObject(wrappedValue: WindowState(singleTabAt: tornOffTabURL))
        } else {
            _window = StateObject(wrappedValue: WindowState())
        }
    }
    /// Sidebar ideal width, persisted across launches. SwiftUI's
    /// NavigationSplitView doesn't expose a live width binding, so we
    /// observe the SidebarView's geometry and write here on change.
    @AppStorage("fe.sidebarWidth") private var sidebarWidthRaw: Double = 220
    @State private var confirmPermanentDelete = false
    @State private var propertiesURL: URL? = nil
    @State private var showBatchRename = false
    /// Drives the FDA / Files & Folders onboarding sheet. Auto-true on
    /// first launch; the user can dismiss it once and re-open it any
    /// time via Help → "Folder Access…".
    @State private var showPermissionGuide = false
    /// One-shot flag: true after the user has dismissed the auto-
    /// presented guide at least once. Persists in @AppStorage so
    /// subsequent launches (or rebuilds — same bundle id) don't keep
    /// popping the sheet.
    @AppStorage("fe.hasShownPermissionGuide") private var hasShownPermissionGuide: Bool = false
    /// Drives the ⌘\ sidebar toggle. `.automatic` shows the sidebar on
    /// macOS; switching to `.detailOnly` hides it. The notification
    /// handler in `splitView` flips between the two.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @AppStorage("fe.showPreview")    private var showPreview: Bool = false
    @AppStorage("fe.showHidden")     private var showHidden:  Bool = false
    @AppStorage("fe.showToolbar")    private var showToolbar: Bool = false
    /// Global view-mode default for folders the user hasn't customised.
    /// Per-folder overrides live in FolderViewModeService.
    @AppStorage("fe.viewMode")       private var viewModeRaw: String = FileViewMode.details.rawValue
    /// Mirrored from `window.tabs.count` so the ⌘1‥⌘9 menu items can
    /// disable shortcuts beyond the current tab count.
    @AppStorage("fe.activeTabCount") private var activeTabCount: Int = 1
    /// Global text-zoom — ⌘+ / ⌘- / ⌘0 from the View menu. Stored as
    /// a raw Double so @AppStorage can persist it; the FEFontScale
    /// enum quantises to one of six discrete steps.
    @AppStorage("fe.fontScale")      private var fontScaleRaw: Double = 1.0

    private var fontScale: FEFontScale { .from(raw: fontScaleRaw) }

    var body: some View {
        splitView
            .environment(\.feFontScale, CGFloat(fontScale.rawValue))
            .dynamicTypeSize(fontScale.dynamicTypeSize)
            // Capture the hosting NSWindow so broadcast menu commands
            // (delivered to every window over NotificationCenter) only
            // run in the frontmost one — see WindowState.cmd(_:).
            .background(WindowAccessor { window.hostWindow = $0 })
            .modifier(WindowCommands(
                window: window, clipboard: clipboard,
                showPreview: $showPreview,
                showHidden: $showHidden,
                viewModeRaw: $viewModeRaw,
                confirmPermanentDelete: $confirmPermanentDelete
            ))
            .onReceive(window.cmd(.feFontSizeIncrease)) { _ in
                fontScaleRaw = fontScale.bumped(by: 1).rawValue
            }
            .onReceive(window.cmd(.feFontSizeDecrease)) { _ in
                fontScaleRaw = fontScale.bumped(by: -1).rawValue
            }
            .onReceive(window.cmd(.feFontSizeReset)) { _ in
                fontScaleRaw = FEFontScale.normal.rawValue
            }
            .onReceive(window.cmd(.feShowProperties)) { _ in
                // ⌘I on an empty selection used to silently do nothing.
                // Fall back to the current folder so the user gets info
                // about *something* — matches Finder's behaviour when
                // the active focus is the window background rather than
                // a file.
                propertiesURL = window.activeTab.selectedURLs.first
                    ?? window.activeTab.currentURL
            }
            .onReceive(window.cmd(.feShowBatchRename)) { _ in
                if window.activeTab.selectedURLs.count >= 2 {
                    showBatchRename = true
                }
            }
            .sheet(item: Binding(
                get: { propertiesURL.map(IdentifiableURL.init) },
                set: { propertiesURL = $0?.url }
            )) { wrap in
                PropertiesDialog(url: wrap.url)
            }
            .sheet(isPresented: $showBatchRename) {
                BatchRenameDialog(urls: window.activeTab.selectedURLs) { mapping in
                    window.activeTab.applyBatchRename(mapping)
                }
            }
            .sheet(isPresented: $showPermissionGuide) {
                PermissionGuideDialog {
                    showPermissionGuide = false
                    hasShownPermissionGuide = true
                }
            }
            .onReceive(window.cmd(.feShowPermissionGuide)) { _ in
                // Help menu entry: re-opens the guide even after the
                // user has dismissed it once.
                showPermissionGuide = true
            }
            .task {
                NotificationService.requestAuthorizationIfNeeded()
                // First-run trigger. Slight delay so the main window's
                // initial animation finishes before the sheet attaches —
                // otherwise the sheet sometimes catches the wrong frame
                // and renders off-centre.
                if !hasShownPermissionGuide {
                    // Claim the one-shot synchronously BEFORE the first
                    // await — `.task` runs on the main actor, so a second
                    // window restored at launch will see `true` here and
                    // skip, instead of both windows popping the sheet.
                    hasShownPermissionGuide = true
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    showPermissionGuide = true
                }
            }
            // The quit-time session save lives in WindowState itself now
            // (weak, removed in deinit) — the observer that used to be
            // registered here strongly captured the WindowState forever,
            // keeping closed windows' tabs and FSEvents watchers alive.
            .onAppear {
                activeTabCount = window.tabs.count
            }
            .onChange(of: window.tabs.count) { _, newCount in
                activeTabCount = newCount
                window.persistSession()
            }
            .onChange(of: window.activeIndex) { _, _ in
                window.persistSession()
            }
    }

    // MARK: - Layout

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(tab: window.activeTab)
                .frame(minWidth: 180, idealWidth: CGFloat(sidebarWidthRaw), maxWidth: 320)
                .background(
                    // Geometry probe — when the user drags the column
                    // separator, the SidebarView's frame changes and we
                    // persist the new width so next launch starts there.
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width) { _, newWidth in
                                let clamped = max(180, min(320, Double(newWidth)))
                                // 0.5pt jitter shouldn't churn UserDefaults.
                                if abs(clamped - sidebarWidthRaw) > 0.5 {
                                    sidebarWidthRaw = clamped
                                }
                            }
                    }
                )
        } detail: {
            VStack(spacing: 0) {
                TabBar(window: window)
                Divider()
                if showToolbar {
                    ActionToolbar(tab: window.activeTab, clipboard: clipboard)
                    Divider()
                }
                paneArea
                Divider()
                StatusBar(tab: window.activeTab)
            }
            // Native macOS window toolbar — view-mode picker centred.
            // The unified style is enabled by `windowToolbarStyle(.unified(...))`
            // in the App struct, so this blends into the title bar.
            // (The search field stays in the AddressBar row below —
            // SwiftUI's toolbar layer doesn't pipe keyboard focus
            // to nested TextFields reliably on macOS, so it renders
            // but doesn't accept typing.)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarViewModePicker(tab: window.activeTab)
                }
                // Preview-pane toggle — surfaced in the toolbar (not
                // just the ⌘⇧P menu item) so the video/audio/image
                // preview feature is actually discoverable. Highlights
                // when the pane is open.
                ToolbarItem(placement: .automatic) {
                    Button {
                        showPreview.toggle()
                    } label: {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(showPreview && !window.isSplit
                                             ? Color.accentColor : Color.primary)
                            // Clearly fade it out in split view — the
                            // default `.disabled` dimming is too subtle.
                            .opacity(window.isSplit ? 0.3 : 1.0)
                    }
                    // The preview pane isn't shown in split view, so the
                    // toggle is disabled there.
                    .disabled(window.isSplit)
                    .help(window.isSplit
                          ? "Preview unavailable in Split View"
                          : (showPreview ? "Hide Preview (⇧⌘P)" : "Show Preview (⇧⌘P)"))
                }
                // Split (dual-pane) toggle — placed at the leading edge,
                // next to the sidebar toggle, for the window-layout
                // controls to sit together.
                ToolbarItem(placement: .navigation) {
                    Button {
                        window.toggleSplit()
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .foregroundStyle(window.isSplit ? Color.accentColor : Color.primary)
                    }
                    .help(window.isSplit ? "Exit Split View (⌥⌘S)" : "Split View (⌥⌘S)")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 880, minHeight: 540)
        .onReceive(window.cmd(.feToggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .automatic : .detailOnly
        }
    }

    /// Single folder browser, or two side-by-side in split view.
    @ViewBuilder
    private var paneArea: some View {
        if window.isSplit, let right = window.rightTab {
            HSplitView {
                PaneBrowser(tab: window.leftTab,
                            isActive: window.activeSide == .left,
                            isSplit: true,
                            showPreview: false,
                            onActivate: { window.focus(.left) })
                    .frame(minWidth: 340)
                PaneBrowser(tab: right,
                            isActive: window.activeSide == .right,
                            isSplit: true,
                            showPreview: false,
                            onActivate: { window.focus(.right) })
                    .frame(minWidth: 340)
            }
        } else {
            PaneBrowser(tab: window.leftTab,
                        isActive: true,
                        isSplit: false,
                        showPreview: showPreview)
        }
    }
}

// MARK: - Command bus + sheets

private struct WindowCommands: ViewModifier {
    @ObservedObject var window: WindowState
    @ObservedObject var clipboard: ClipboardService
    @Binding var showPreview: Bool
    @Binding var showHidden: Bool
    @Binding var viewModeRaw: String
    @Binding var confirmPermanentDelete: Bool

    func body(content: Content) -> some View {
        content
            .modifier(NavigationCommands(window: window))
            .modifier(TabCommands(window: window))
            .modifier(EditCommands(window: window, clipboard: clipboard,
                                   confirmPermanentDelete: $confirmPermanentDelete))
            .modifier(ViewToggleCommands(showPreview: $showPreview,
                                          showHidden: $showHidden,
                                          viewModeRaw: $viewModeRaw,
                                          window: window))
            .modifier(SheetPresentation(window: window,
                                         tab: window.activeTab,
                                         confirmPermanentDelete: $confirmPermanentDelete))
    }
}

private struct NavigationCommands: ViewModifier {
    @ObservedObject var window: WindowState
    func body(content: Content) -> some View {
        content
            .onReceive(window.cmd(.feGoBack))    { _ in window.activeTab.goBack() }
            .onReceive(window.cmd(.feGoForward)) { _ in window.activeTab.goForward() }
            .onReceive(window.cmd(.feGoUp))      { _ in window.activeTab.goUp() }
            .onReceive(window.cmd(.feReload))    { _ in window.activeTab.reload() }
    }
}

private struct TabCommands: ViewModifier {
    @ObservedObject var window: WindowState
    func body(content: Content) -> some View {
        content
            .onReceive(window.cmd(.feNewTab))           { _ in window.newTab() }
            .onReceive(window.cmd(.feCloseTab))         { _ in window.closeActiveTab() }
            .onReceive(window.cmd(.feReopenClosedTab))  { _ in window.reopenLastClosed() }
            .onReceive(window.cmd(.feSelectTab)) { note in
                if let idx = note.userInfo?["index"] as? Int { window.selectTab(at: idx) }
            }
    }
}

/// True when keyboard focus sits in a text editor — the address bar,
/// the search field, or an inline rename field (each is backed by an
/// NSTextView field editor when focused). The Edit-menu shortcuts must
/// then act on the TEXT, not the file selection: our CommandGroup
/// replaces ⌘C/⌘X/⌘V/⌘A app-wide, so without this check ⌘V during a
/// rename pasted FILES into the folder and ⌘C in the address bar
/// clobbered the file clipboard.
@MainActor
private func textEditingActive() -> Bool {
    NSApp.keyWindow?.firstResponder is NSTextView
}

/// Forward a standard text-editing action (`"copy:"`, `"paste:"` …)
/// down the responder chain so the focused field editor handles it —
/// what the system Edit menu would have done had we not replaced it.
@MainActor
private func forwardToTextEditor(_ selector: String) {
    NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil)
}

private struct EditCommands: ViewModifier {
    @ObservedObject var window: WindowState
    @ObservedObject var clipboard: ClipboardService
    @Binding var confirmPermanentDelete: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(window.cmd(.feNewFolder))     { _ in window.activeTab.createNewFolder() }
            // Empty-selection guard on ⌘C/⌘X: `copy([])` would REPLACE
            // the clipboard with nothing, so a stray press silently
            // wiped a pending copy and the next ⌘V did nothing. Finder
            // greys the menu items out in this state; we no-op.
            .onReceive(window.cmd(.feCutSelection))  { _ in
                if textEditingActive() { forwardToTextEditor("cut:"); return }
                let urls = window.activeTab.selectedURLs
                guard !urls.isEmpty else { return }
                clipboard.cut(urls)
            }
            .onReceive(window.cmd(.feCopySelection)) { _ in
                if textEditingActive() { forwardToTextEditor("copy:"); return }
                let urls = window.activeTab.selectedURLs
                guard !urls.isEmpty else { return }
                clipboard.copy(urls)
            }
            .onReceive(window.cmd(.fePaste)) { _ in
                if textEditingActive() { forwardToTextEditor("paste:"); return }
                window.activeTab.paste()
            }
            .onReceive(window.cmd(.feMoveSelectionToTrash)) { _ in
                // ⌘⌫ while editing text = "delete to start of line"
                // (the system text binding), NOT trash the file whose
                // name is being edited.
                if textEditingActive() { forwardToTextEditor("deleteToBeginningOfLine:"); return }
                window.activeTab.moveSelectedToTrash()
            }
            .onReceive(window.cmd(.feDeleteSelectionPermanently)) { _ in
                guard !textEditingActive() else { return }
                guard !window.activeTab.selectedURLs.isEmpty else { return }
                confirmPermanentDelete = true
            }
            .onReceive(window.cmd(.feRenameSelection)) { _ in
                // Already renaming (or typing elsewhere) — don't restart.
                guard !textEditingActive() else { return }
                window.activeTab.beginRenameSelected()
            }
            .onReceive(window.cmd(.feCopyPath)) { _ in
                // Selection wins; if nothing is selected, fall back to
                // the current folder so the same shortcut handles both
                // "copy file path" and "copy folder path".
                let urls = window.activeTab.selectedURLs.isEmpty
                    ? [window.activeTab.currentURL]
                    : window.activeTab.selectedURLs
                ClipboardService.copyPathsToPasteboard(urls)
            }
            .onReceive(window.cmd(.feDuplicateSelection)) { _ in
                window.activeTab.duplicateSelected()
            }
            .onReceive(window.cmd(.feSelectAll)) { _ in
                if textEditingActive() { forwardToTextEditor("selectAll:"); return }
                window.activeTab.selectAllVisible()
            }
            .onReceive(window.cmd(.feUndo)) { _ in
                // Text fields keep their own undo stack — ⌘Z while
                // typing must undo TYPING, not the last file operation.
                if textEditingActive() { forwardToTextEditor("undo:"); return }
                window.activeTab.performUndo()
            }
            .onReceive(window.cmd(.feRedo)) { _ in
                if textEditingActive() { forwardToTextEditor("redo:"); return }
                window.activeTab.performRedo()
            }
    }
}

private struct ViewToggleCommands: ViewModifier {
    @Binding var showPreview: Bool
    @Binding var showHidden: Bool
    @Binding var viewModeRaw: String
    @ObservedObject var window: WindowState

    func body(content: Content) -> some View {
        content
            .onReceive(window.cmd(.feTogglePreview)) { _ in
                showPreview.toggle()
            }
            .onReceive(window.cmd(.feToggleSplit)) { _ in
                window.toggleSplit()
            }
            .onReceive(window.cmd(.feSetViewMode)) { note in
                guard let raw = note.userInfo?["mode"] as? String,
                      let mode = FileViewMode(rawValue: raw) else { return }
                // Per-folder override so this exact folder remembers
                // the choice, plus update the global default so newly
                // visited folders inherit the most-recent preference.
                FolderViewModeService.shared.setMode(mode, for: window.activeTab.currentURL)
                viewModeRaw = raw
            }
            .onReceive(window.cmd(.feSetGroupBy)) { note in
                if let raw = note.userInfo?["key"] as? String,
                   let key = GroupKey(rawValue: raw) {
                    window.activeTab.groupBy = key
                }
            }
            .onChange(of: showHidden) { _, newValue in
                for tab in window.tabs where tab.showHidden != newValue {
                    tab.showHidden = newValue
                }
            }
            .onAppear {
                for tab in window.tabs where tab.showHidden != showHidden {
                    tab.showHidden = showHidden
                }
            }
    }
}

private struct SheetPresentation: ViewModifier {
    @ObservedObject var window: WindowState
    /// The active tab, observed directly so the permanent-delete dialog
    /// reads a live selection count. (The transfer-progress sheet lives
    /// in PaneBrowser now — per pane — and the conflict prompt is an
    /// NSAlert in ConflictPrompt, so neither is presented here.)
    @ObservedObject var tab: TabViewModel
    @Binding var confirmPermanentDelete: Bool

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Delete permanently?",
                isPresented: $confirmPermanentDelete,
                titleVisibility: .visible
            ) {
                Button("Delete \(tab.selectedURLs.count) item\(tab.selectedURLs.count == 1 ? "" : "s")",
                       role: .destructive) {
                    tab.permanentlyDeleteSelected()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These items will be removed immediately and cannot be recovered. Use \u{2318}\u{232B} instead to move them to the Trash.")
            }
    }
}

/// Resolves the NSWindow hosting this SwiftUI view and hands it back, so
/// command routing can tell which window is frontmost. The view itself
/// is invisible and never intercepts hit-testing.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // `view.window` is nil until the view is in the hierarchy — defer
        // one runloop hop so it's attached.
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Self-heal without per-render dispatch churn: assign directly
        // when attached (cheap weak-pointer write); only defer while the
        // view hasn't joined a window yet.
        if let w = nsView.window {
            onResolve(w)
        } else {
            DispatchQueue.main.async { onResolve(nsView.window) }
        }
    }
}

/// Wraps a URL so it can satisfy `.sheet(item:)`'s Identifiable
/// requirement (URL itself is Hashable but not Identifiable in Swift's
/// stdlib).
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: URL { url }
    init(_ url: URL) { self.url = url }
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var tab: TabViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text(itemSummary)
                .monospacedDigit()
            if !tab.selectedIDs.isEmpty {
                Divider().frame(height: 12)
                Text(selectionSummary)
                    .monospacedDigit()
            }
            if let free = freeSpaceText {
                Divider().frame(height: 12)
                Text(free)
                    .monospacedDigit()
                    .help("Free space on the volume containing this folder")
            }
            Spacer()
            Text(tab.currentURL.path)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption.monospaced())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// "23 items (5 folders, 18 files)" — folder/file split is what
    /// every modern file manager shows. Falls back to the plain count
    /// for very small folders where the split is uninteresting.
    ///
    /// Reads `visibleItems` (search + kind/size/date filters applied),
    /// NOT the raw `items` — the bar used to always show the folder's
    /// total count regardless of an active search, which read as "the
    /// search isn't doing anything" even when the list itself was
    /// filtering correctly.
    private var itemSummary: String {
        let visible = tab.visibleItems
        let total = visible.count
        let folders = visible.filter { $0.isDirectory && !$0.isPackage }.count
        let files = total - folders
        if total == 0 {
            return tab.searchQuery.isEmpty ? "Empty folder" : "No matches"
        }
        if folders == 0 || files == 0 {
            // Pure folder or pure file directory.
            return "\(total) item\(total == 1 ? "" : "s")"
        }
        return "\(total) items · \(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
    }

    private var selectionSummary: String {
        let count = tab.selectedIDs.count
        // Same fix as `itemSummary` — a selected search result from
        // outside the current folder isn't in `tab.items`, so the old
        // lookup silently dropped its size from the total.
        let totalBytes = tab.visibleItems
            .filter { tab.selectedIDs.contains($0.url) }
            .compactMap { $0.size }
            .reduce(Int64(0), +)
        if totalBytes > 0 {
            return "\(count) selected · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
        }
        return "\(count) selected"
    }

    /// "1.2 TB free" — uses Foundation's resource-value cache so the
    /// underlying `statfs` only runs once per volume between
    /// invalidations. Returns nil for paths that can't be queried
    /// (e.g. permission-denied roots like /private/var/db).
    private var freeSpaceText: String? {
        guard let bytes = FreeSpaceProbe.shared.freeBytes(for: tab.currentURL) else {
            return nil
        }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(formatted) free"
    }
}

/// Throttled free-space probe. SwiftUI re-renders the StatusBar on
/// any tab-state change (selection, scroll, search…), so wrapping
/// `URLResourceKey.volumeAvailableCapacity` in a 5s per-volume cache
/// keeps the call out of every redraw without making the number stale.
@MainActor
private final class FreeSpaceProbe {
    static let shared = FreeSpaceProbe()

    private var cache: [String: (bytes: Int64, fetchedAt: Date)] = [:]
    private let staleAfter: TimeInterval = 5

    func freeBytes(for url: URL) -> Int64? {
        // Identify the volume root so two folders on the same disk
        // share a cache entry — Macintosh HD with thousands of folders
        // shouldn't multiply the cache.
        let keys: Set<URLResourceKey> = [.volumeURLKey]
        let volumeURL = (try? url.resourceValues(forKeys: keys))?.volume ?? url
        let volumePath = volumeURL.path

        if let hit = cache[volumePath],
           Date().timeIntervalSince(hit.fetchedAt) < staleAfter {
            return hit.bytes
        }

        let capacityKeys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? volumeURL.resourceValues(forKeys: capacityKeys) else {
            return nil
        }
        // `important` is what Finder shows — accounts for purgeable
        // iCloud caches that the system can reclaim on demand. Falls
        // back to the raw capacity for older volumes that don't
        // expose it.
        let bytes = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        cache[volumePath] = (bytes, Date())
        return bytes > 0 ? bytes : nil
    }
}
