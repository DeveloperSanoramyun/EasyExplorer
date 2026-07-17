//
//  TabViewModel.swift
//  FileExplorer
//
//  Per-tab state: current URL, back/forward history, selection, sort,
//  plus the in-flight file operation (progress + conflict prompt).
//

import Foundation
import AppKit
import Combine

@MainActor
final class TabViewModel: ObservableObject, Identifiable {

    /// Stable per-instance identifier used by TabBar's ForEach so a tab
    /// drag-reorder doesn't recreate every chip (and lose hover state)
    /// the way `id: \.offset` did before this was added.
    nonisolated let id = UUID()

    // MARK: Published state

    @Published private(set) var currentURL: URL {
        didSet {
            // Any folder change abandons an in-flight inline rename.
            // Without this, `renamingItemID` would keep pointing at the
            // OLD folder's file: no field renders (no matching row) yet
            // every KeyboardHandler action is gated on
            // `renamingItemID == nil`, leaving the keyboard dead until
            // the user clicks a row. Covers navigate / goBack / goForward
            // / goBack(to:) / goForward(to:) in one place.
            if oldValue != currentURL { renamingItemID = nil }
        }
    }
    @Published private(set) var items: [FileItem] = []
    @Published var selectedIDs: Set<URL> = []

    /// Anchor item for ⇧-click range selection. Set by single click /
    /// ⌘-click; consumed by `selectRange(to:)`. Cleared on navigation
    /// and pruned when the anchored item disappears.
    @Published private(set) var selectionAnchor: URL? = nil

    // Sort is persisted across launches via UserDefaults so the user
    // doesn't have to re-pick "Date Modified" every time. The global
    // key is the default for unseen folders; per-folder overrides live
    // in FolderSortService and are applied on navigation.
    @Published var sortKey: FileItem.SortKey =
        FileItem.SortKey(rawValue: UserDefaults.standard.string(forKey: "fe.sortKey") ?? "")
            ?? .name {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "fe.sortKey")
            persistFolderSort()
        }
    }
    @Published var sortAscending: Bool =
        UserDefaults.standard.object(forKey: "fe.sortAscending") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "fe.sortAscending")
            persistFolderSort()
        }
    }

    /// Guard so the per-folder save doesn't fire during the initial
    /// load (when we set sortKey from disk while constructing the tab).
    private var sortPersistenceEnabled: Bool = false

    private func persistFolderSort() {
        guard sortPersistenceEnabled else { return }
        FolderSortService.shared.setPreference(sortKey, ascending: sortAscending, for: currentURL)
    }

    /// Apply the saved per-folder sort if any. Called whenever the tab
    /// arrives at a new folder.
    private func applyFolderSort() {
        sortPersistenceEnabled = false
        defer { sortPersistenceEnabled = true }
        if let pref = FolderSortService.shared.preference(for: currentURL) {
            if sortKey != pref.key { sortKey = pref.key }
            if sortAscending != pref.ascending { sortAscending = pref.ascending }
        }
    }

    // Hidden-file visibility is also persisted — and the View menu's
    // Toggle reads/writes the same key so its checkmark stays in sync.
    @Published var showHidden: Bool =
        UserDefaults.standard.bool(forKey: "fe.showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "fe.showHidden")
            reload()
        }
    }

    /// Folder-READ failure only (permission denied, missing folder…).
    /// Non-nil replaces the file list with the full-pane error state.
    /// Operation failures (trash, rename, busy-transfer…) must NOT go
    /// here — they use `opErrorMessage` and render as a banner ABOVE a
    /// still-visible listing.
    @Published var errorMessage: String? = nil

    /// Transient operation-error banner ("couldn't trash 2 items",
    /// "another operation in progress"…). Auto-clears after a few
    /// seconds; the listing stays interactive underneath.
    @Published var opErrorMessage: String? = nil
    private var opErrorDismissWork: DispatchWorkItem? = nil

    /// Surface an operation failure without nuking the file list.
    func reportOpError(_ message: String) {
        opErrorMessage = message
        opErrorDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.opErrorMessage = nil }
        opErrorDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Transient in-app success banner ("Moved 3 items"). Used as the
    /// fallback for `NotificationService.notifyOperationCompleted` when
    /// the user has denied (or not yet responded to) the system
    /// notification permission — without this, a completed multi-hour
    /// transfer produced no feedback anywhere once notifications were
    /// off. Auto-clears faster than the error banner since it's not
    /// something the user needs time to read/act on.
    @Published var successMessage: String? = nil
    private var successDismissWork: DispatchWorkItem? = nil

    func reportSuccess(_ message: String) {
        successMessage = message
        successDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.successMessage = nil }
        successDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Set when `listDirectory` throws a TCC-protected `permissionDenied`
    /// error. Drives the "Grant Full Disk Access" guidance panel so the
    /// user has a direct path to fixing the access denial.
    @Published var permissionBlockedURL: URL? = nil

    // Grouping (P2-1). When non-`.none`, the file list renders with
    // collapsible section headers instead of a flat table.
    @Published var groupBy: GroupKey = .none

    // FSEvents watcher — re-points whenever currentURL changes so the
    // visible folder always reflects what's on disk.
    private let watcher = FileWatcherService()

    // Combine forwarder — re-broadcasts SpotlightSearchService changes
    // through our own objectWillChange so SwiftUI re-renders dependent
    // views (`visibleItems` etc.) without having to subscribe twice.
    private var spotlightForwarder: AnyCancellable?

    // Inline rename state — when non-nil, the file list renders a
    // TextField in that row instead of plain text.
    @Published var renamingItemID: URL? = nil

    /// When the last inline rename ended (committed OR cancelled). The
    /// gesture views' slow-click rename consults this so the very click
    /// that DISMISSES a rename (commit-on-outside-click) can't instantly
    /// re-arm a brand-new rename on the same row — the bug where clicking
    /// a renaming file's icon dropped you straight back into edit mode.
    /// Plain stored property (not @Published): it's polled at click time,
    /// never rendered.
    private(set) var lastRenameEndedAt: Date = .distantPast
    /// True if a rename ended within the last 0.8 s.
    var renameRecentlyEnded: Bool {
        Date().timeIntervalSince(lastRenameEndedAt) < 0.8
    }

    // Search filter (Sprint 4) — narrows the visible items in the current
    // folder. Stored on the tab so each tab has its own query (matches
    // Windows Explorer per-tab search behaviour).
    @Published var searchQuery: String = "" {
        didSet { searchQueryChanged() }
    }

    /// Scope of the active search.
    enum SearchScope {
        case folder       // Local filter — items in `currentURL`
        case thisMac      // System-wide Spotlight query (Sprint P1-6)
    }
    @Published var searchScope: SearchScope = .folder {
        didSet {
            // A user-driven scope change always exits tag mode — the
            // snapshot only existed to dodge an immediate filename-
            // search overwrite for the same string when seeding a tag
            // search. The `suppressScopeReset` flag lets
            // `searchByTag(_:)` set the scope programmatically without
            // tripping this clear (and re-issuing a filename query)
            // before it has a chance to install the snapshot.
            if !suppressScopeReset {
                tagSearchSnapshot = nil
            }
            searchQueryChanged()
        }
    }

    /// Set by `searchByTag(_:)` while it primes the scope + query, so
    /// the `searchScope` didSet doesn't nuke our impending tagSearchSnapshot.
    private var suppressScopeReset: Bool = false

    /// Spotlight search results when scope == .thisMac. nil otherwise.
    @Published var spotlightService: SpotlightSearchService? = nil

    // MARK: Search filters

    /// Optional kind filter applied on top of the search query. `.all`
    /// means "don't filter by kind"; the others bucket items the same
    /// way GroupKey.type does.
    @Published var searchKindFilter: KindFilter = .all {
        didSet { objectWillChange.send() }
    }
    @Published var searchSizeFilter: SizeFilter = .all {
        didSet { objectWillChange.send() }
    }
    @Published var searchDateFilter: DateFilter = .all {
        didSet { objectWillChange.send() }
    }
    /// Manually toggled via AddressBar's funnel button so the kind/size/
    /// date filter chips are reachable even when the user isn't
    /// currently searching — `visibleItems` already applies these
    /// filters unconditionally (see `hasActiveSearchFilter`); this flag
    /// only controls whether `SearchFilterBar` is showing so there's a
    /// way to SET a filter from a cold start (no search, no filter yet).
    @Published var filterBarVisible: Bool = false

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All Kinds"
        case folder = "Folder"
        case image = "Image"
        case video = "Video"
        case audio = "Audio"
        case document = "Document"
        case archive = "Archive"
        case code = "Code"
        var id: String { rawValue }
    }

    enum SizeFilter: String, CaseIterable, Identifiable {
        case all = "Any Size"
        case tiny = "< 100 KB"
        case small = "< 1 MB"
        case medium = "< 16 MB"
        case large = "< 128 MB"
        case huge = "≥ 128 MB"
        var id: String { rawValue }
    }

    enum DateFilter: String, CaseIterable, Identifiable {
        case all = "Any Time"
        case today = "Today"
        case yesterday = "Yesterday"
        case lastWeek = "Last 7 Days"
        case lastMonth = "Last 30 Days"
        case thisYear = "Earlier This Year"
        var id: String { rawValue }
    }

    var hasActiveSearchFilter: Bool {
        searchKindFilter != .all || searchSizeFilter != .all || searchDateFilter != .all
    }

    func resetSearchFilters() {
        searchKindFilter = .all
        searchSizeFilter = .all
        searchDateFilter = .all
    }

    // In-flight operation state (Sprint 3)
    @Published var transferProgress: FileOperationProgress? = nil
    /// Gates the progress SHEET (separate from `transferProgress`, which
    /// always tracks the live op for `hasActiveTransfer`). The sheet is
    /// shown only after a short delay — a fast operation finishes first
    /// and never pops a dialog — and is auto-dismissed on success.
    @Published var transferDialogVisible: Bool = false

    /// True while a copy/move/compress/extract is mid-flight. Used to
    /// block a second operation from clobbering the active sheet's
    /// progress object and silently orphaning the first Task.
    var hasActiveTransfer: Bool {
        guard let p = transferProgress else { return false }
        return !p.isDone
    }

    /// Start tracking an op and arm the delayed sheet. Call instead of
    /// `transferProgress = progress`.
    func beginTransferSheet(_ progress: FileOperationProgress) {
        transferProgress = progress
        transferDialogVisible = false
        // Only pop the dialog if the op is still running after a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.transferProgress === progress, !progress.isDone else { return }
            self.transferDialogVisible = true
        }
    }

    /// Called when an op finishes. Auto-dismisses the sheet on success
    /// (after a brief "Done" flash if it was visible); keeps it open on
    /// error so the user can read it.
    func finishTransferSheet(_ progress: FileOperationProgress) {
        guard transferProgress === progress else { return }
        if progress.errorMessage != nil {
            transferDialogVisible = true            // always surface errors
        } else if transferDialogVisible {
            // Visible success → flash "Done", then close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.transferProgress === progress else { return }
                self.transferProgress = nil
                self.transferDialogVisible = false
            }
        } else {
            // Fast op — never shown, clean up silently.
            transferProgress = nil
        }
    }

    // MARK: History

    private var back: [URL] = []
    private var forward: [URL] = []

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }

    /// Back history in chronological order (oldest first). The address
    /// bar's ▾ dropdown reverses this to show the most recent at the
    /// top, matching every browser.
    var backHistory: [URL] { back }
    var forwardHistory: [URL] { forward }

    // MARK: Init

    init(startAt url: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = url
        applyFolderSort()
        reload()
        startWatching()
        sortPersistenceEnabled = true
    }

    deinit { watcher.stop() }

    private func startWatching() {
        watcher.watch(currentURL) { [weak self] in
            // FSEvents already coalesces inside its 0.5s latency
            // window, but a folder receiving a flood of writes (a big
            // download / `tar -x`) still drives many callbacks. Add a
            // 300 ms post-event quiet period so reload fires at most
            // once per chunk of activity, not per chunk-of-FSEvent.
            self?.scheduleReload()
        }
    }

    /// Coalesce reload requests from FSEvents so a stream of changes
    /// doesn't drive a stream of full directory enumerations. The
    /// latest call wins — older pending reloads are cancelled.
    private var reloadDebounceTask: Task<Void, Never>?

    private func scheduleReload() {
        reloadDebounceTask?.cancel()
        reloadDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.reload()
            }
        }
    }

    // MARK: Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        // Only refuse if the target isn't a directory at all (doesn't
        // exist, or is a regular file) — for that case leaving the user
        // where they are with an error makes sense.
        //
        // For directories we ALWAYS commit the navigation, even when
        // LaunchServices/POSIX reports them as unreadable (Downloads,
        // Documents, ~/Library/... under TCC). `reload()` knows how to
        // surface those as an empty folder with the "Access Denied" /
        // "Open System Settings" overlay; bailing early here used to
        // leave the previous folder's items rendered behind the error,
        // which looked like a corruption bug.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            reportOpError("Cannot open \(url.lastPathComponent): not a directory.")
            return
        }
        if recordHistory { back.append(currentURL); forward.removeAll() }
        currentURL = url
        selectedIDs.removeAll()
        selectionAnchor = nil
        // Clear the query BEFORE the scope: setting scope first would
        // fire `searchQueryChanged()` with the old (non-empty) text and
        // briefly start a Spotlight query for the previous search scoped
        // to the new folder. Emptying the query first tears Spotlight
        // down cleanly. (Each folder starts query-less — Windows-style.)
        searchQuery = ""
        searchScope = .folder
        // Filter chips are per-location too (see resetSearchForNavigation).
        if hasActiveSearchFilter { resetSearchFilters() }
        filterBarVisible = false
        applyFolderSort()
        reload()
        startWatching()     // re-aim FSEvents at the new directory
        BookmarkService.shared.recordVisit(url)
    }

    func goBack()    { guard let p = back.popLast()    else { return }; forward.append(currentURL); currentURL = p; selectedIDs.removeAll(); selectionAnchor = nil; resetSearchForNavigation(); applyFolderSort(); reload(); startWatching() }
    func goForward() { guard let n = forward.popLast() else { return }; back.append(currentURL); currentURL = n; selectedIDs.removeAll(); selectionAnchor = nil; resetSearchForNavigation(); applyFolderSort(); reload(); startWatching() }
    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    /// Jump to a specific entry in the back history (history dropdown).
    /// All entries newer than `target` (plus the current URL itself)
    /// get shovelled onto the forward stack so a subsequent `goForward`
    /// retraces the user's path.
    func goBack(to target: URL) {
        guard let idx = back.lastIndex(of: target) else { return }
        // Everything strictly after `target` in `back`, plus current URL,
        // moves to forward. Reversed so popLast() yields them in the
        // user's original chronological order.
        let bumped = Array(back.suffix(from: idx + 1)) + [currentURL]
        forward.append(contentsOf: bumped.reversed())
        back = Array(back.prefix(idx))
        currentURL = target
        selectedIDs.removeAll()
        selectionAnchor = nil
        resetSearchForNavigation()
        applyFolderSort()
        reload()
        startWatching()
    }

    /// Mirror of `goBack(to:)` for the forward stack — used by the ▾
    /// dropdown next to the Forward button.
    func goForward(to target: URL) {
        guard let idx = forward.lastIndex(of: target) else { return }
        // forward[idx] is the destination. Items AFTER idx in `forward`
        // are "between" current and target; they go back onto the back
        // stack so the user can rewind.
        let beforeTarget = Array(forward.suffix(from: idx + 1)).reversed()
        back.append(currentURL)
        back.append(contentsOf: beforeTarget)
        forward = Array(forward.prefix(idx))
        currentURL = target
        selectedIDs.removeAll()
        selectionAnchor = nil
        resetSearchForNavigation()
        applyFolderSort()
        reload()
        startWatching()
    }

    /// Clear any active search when navigating via history. `navigate`
    /// already does this inline (each fresh folder starts query-less,
    /// matching Windows), but Back/Forward used to skip it — leaving a
    /// folder-scoped Spotlight query alive and pointed at the *previous*
    /// folder, so its subtree results bled into the new listing.
    /// Guarded so we don't churn `searchQueryChanged()` when no search
    /// is active.
    private func resetSearchForNavigation() {
        // Kind/size/date chips are per-location, like Finder/Explorer —
        // a "Images only" filter set in Downloads shouldn't silently
        // hide files in the next folder. Collapse the manually-opened
        // bar too so the next folder starts clean.
        if hasActiveSearchFilter { resetSearchFilters() }
        filterBarVisible = false
        guard !searchQuery.isEmpty || searchScope != .folder else { return }
        // Clear the query BEFORE the scope (matching `navigate`) — the
        // reverse order briefly fires a Spotlight query for the old text
        // scoped to the new folder before tearing it down.
        searchQuery = ""
        searchScope = .folder
    }

    // MARK: Reload / sort

    func reload() {
        errorMessage = nil
        permissionBlockedURL = nil
        do {
            let list = try FileSystemService.listDirectory(at: currentURL, includeHidden: showHidden)
            items = sorted(list)
            // Prune selection of URLs that no longer exist after the
            // listing refresh — external rename / delete via Finder /
            // Terminal would otherwise leave dangling IDs that fail
            // every subsequent operation silently.
            let liveIDs = Set(items.map(\.url))
            if !selectedIDs.isSubset(of: liveIDs) {
                selectedIDs.formIntersection(liveIDs)
            }
            // Drop the shift-click anchor if the item it pointed at is
            // gone — otherwise a ⇧-click would extend from an invisible
            // pivot and produce surprising selections.
            if let anchor = selectionAnchor, !liveIDs.contains(anchor) {
                selectionAnchor = nil
            }
            // Abandon an inline rename whose file vanished externally
            // (Finder/Terminal delete or move while editing) — same
            // stuck-keyboard hazard as the navigation case.
            if let r = renamingItemID, !liveIDs.contains(r) {
                renamingItemID = nil
            }
            // Invalidate cached folder sizes for items that no longer
            // exist. Other entries stay cached — the user paid for
            // them once and the underlying tree may not have changed.
            FolderSizeService.shared.invalidateMissing(from: liveIDs, in: currentURL)
            // Stop inline audio preview if the playing track just
            // vanished from the listing (trashed / deleted / moved) —
            // otherwise it keeps playing for a file that's no longer
            // visible anywhere.
            if let playing = AudioPreviewService.shared.playingURL,
               !liveIDs.contains(playing) {
                AudioPreviewService.shared.stop()
            }
        } catch let err as FileSystemServiceError {
            items = []
            selectedIDs.removeAll()
            selectionAnchor = nil
            errorMessage = err.localizedDescription
            // Surface a separate flag for TCC-protected paths so the UI
            // can render an "Open System Settings" button rather than
            // just text.
            if case .permissionDenied(let url, let isTCC) = err, isTCC {
                permissionBlockedURL = url
            }
        } catch {
            items = []
            selectedIDs.removeAll()
            selectionAnchor = nil
            errorMessage = "\(error.localizedDescription)"
        }
    }

    func setSort(_ key: FileItem.SortKey) {
        if sortKey == key { sortAscending.toggle() }
        else { sortKey = key; sortAscending = true }
        items = sorted(items)
    }

    private func sorted(_ list: [FileItem]) -> [FileItem] {
        let dirs = list.filter { $0.isDirectory && !$0.isPackage }
        let files = list.filter { !($0.isDirectory && !$0.isPackage) }
        let cmp: (FileItem, FileItem) -> Bool
        switch sortKey {
        case .name:
            cmp = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .typeLabel:
            cmp = { $0.typeLabel.localizedStandardCompare($1.typeLabel) == .orderedAscending }
        case .dateLastOpened:
            // dateAccessed = "Date Last Opened" in Finder terms.
            cmp = { ($0.dateAccessed ?? .distantPast) < ($1.dateAccessed ?? .distantPast) }
        case .dateModified:
            cmp = { ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast) }
        case .dateCreated:
            cmp = { ($0.dateCreated ?? .distantPast) < ($1.dateCreated ?? .distantPast) }
        case .size:
            cmp = { ($0.size ?? -1) < ($1.size ?? -1) }
        case .tags:
            // Sort by the first tag name; untagged items collate last.
            // Stable secondary on name keeps groups within the same tag
            // alphabetised instead of arbitrary.
            cmp = { lhs, rhs in
                let l = lhs.tagNames.first ?? "\u{10FFFF}"
                let r = rhs.tagNames.first ?? "\u{10FFFF}"
                let primary = l.localizedStandardCompare(r)
                if primary != .orderedSame { return primary == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        let order = sortAscending ? cmp : { !cmp($0, $1) }
        return dirs.sorted(by: order) + files.sorted(by: order)
    }

    // MARK: Undo / Redo

    /// Per-tab undo stack. Each operation supplies its own undo and
    /// redo closures; the stack is purely in-memory and scoped to
    /// this tab, so closing the tab discards its history. 50 deep is
    /// enough to recover from "I made a few wrong renames in a row"
    /// without unbounded memory.
    private struct UndoableOperation {
        let actionName: String
        let undo: () -> Void
        let redo: () -> Void
    }
    private var undoStack: [UndoableOperation] = []
    private var redoStack: [UndoableOperation] = []
    private let undoStackLimit = 50

    /// Drives the Edit menu's Undo / Redo enabled state + label.
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published private(set) var undoActionName: String = ""
    @Published private(set) var redoActionName: String = ""

    fileprivate func recordUndoable(actionName: String,
                                    undo: @escaping () -> Void,
                                    redo: @escaping () -> Void) {
        undoStack.append(UndoableOperation(actionName: actionName,
                                           undo: undo, redo: redo))
        if undoStack.count > undoStackLimit {
            undoStack.removeFirst()
        }
        // Any new operation invalidates the redo stack — standard
        // undo-tree → linear-history collapse.
        redoStack.removeAll()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoActionName = undoStack.last?.actionName ?? ""
        redoActionName = redoStack.last?.actionName ?? ""
    }

    func performUndo() {
        guard let op = undoStack.popLast() else { return }
        op.undo()
        redoStack.append(op)
        refreshUndoState()
    }

    func performRedo() {
        guard let op = redoStack.popLast() else { return }
        op.redo()
        undoStack.append(op)
        refreshUndoState()
    }

    // MARK: Selection helpers

    /// URLs of currently selected items (resolved against the live `items`).
    var selectedURLs: [URL] {
        items.filter { selectedIDs.contains($0.url) }.map(\.url)
    }

    /// Replace the selection with a single item and arm the shift-click
    /// anchor on it — the same thing every file manager does on a plain
    /// click.
    func selectOnly(_ url: URL) {
        selectedIDs = [url]
        selectionAnchor = url
    }

    /// Toggle one item in/out of the selection (⌘-click) and update the
    /// anchor so a subsequent ⇧-click extends from this item.
    func toggleSelection(_ url: URL) {
        if selectedIDs.contains(url) {
            selectedIDs.remove(url)
        } else {
            selectedIDs.insert(url)
        }
        selectionAnchor = url
    }

    /// Internal hook for views (Details Table) that don't go through
    /// our explicit `selectOnly/toggleSelection/selectRange` API — they
    /// can still keep the anchor consistent by calling this whenever a
    /// click lands. Leading underscore so it's clearly "internal use".
    func _setAnchor(_ url: URL?) {
        selectionAnchor = url
    }

    /// Select every visible item. ⌘A standard.
    func selectAllVisible() {
        let urls = visibleItems.map(\.url)
        selectedIDs = Set(urls)
        selectionAnchor = urls.first
    }

    /// Select every visible item between the anchor and `url` inclusive.
    /// Falls back to selecting just `url` if there's no anchor. The anchor
    /// stays put so successive ⇧-clicks always grow / shrink from the
    /// same pivot — Finder / Explorer behaviour.
    func selectRange(to url: URL) {
        let visible = visibleItems
        guard let endIdx = visible.firstIndex(where: { $0.url == url }) else {
            return
        }
        let startIdx: Int
        if let anchor = selectionAnchor,
           let idx = visible.firstIndex(where: { $0.url == anchor }) {
            startIdx = idx
        } else {
            startIdx = endIdx
            selectionAnchor = url
        }
        let (lo, hi) = startIdx <= endIdx ? (startIdx, endIdx) : (endIdx, startIdx)
        selectedIDs = Set(visible[lo...hi].map(\.url))
    }

    /// Items bucketed by the current `groupBy` key. For `.none`, returns
    /// a single bucket with the entire list. Buckets come back in a
    /// stable order defined by `GroupKey.sortOrder`.
    var groupedItems: [(bucket: String, items: [FileItem])] {
        let key = groupBy
        let visible = visibleItems
        guard key != .none else { return [("", visible)] }
        let groups = Dictionary(grouping: visible) { key.bucket(for: $0) }
        return groups
            .sorted { key.sortOrder(of: $0.key) < key.sortOrder(of: $1.key) }
            .map { (bucket: $0.key, items: $0.value) }
    }

    /// Items the user actually sees — folder listing, local filter, or
    /// Spotlight results depending on `searchScope` + `searchQuery`,
    /// further trimmed by the active kind/size/date filter chips.
    var visibleItems: [FileItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [FileItem]
        if q.isEmpty {
            base = items
        } else if searchScope == .thisMac {
            // System-wide: results come exclusively from Spotlight.
            // Spotlight returns relevance order; pipe through our
            // sorter so column-header clicks re-order globally.
            base = sorted(spotlightService?.results.compactMap { FileItem.from(url: $0) } ?? [])
        } else {
            // Folder scope: in-memory `items.filter` gives instant
            // direct-child matches while Spotlight (scoped to
            // currentURL) catches subdirectory matches. Merge,
            // dedupe by URL, then sort.
            let local = items.filter { $0.name.localizedCaseInsensitiveContains(q) }
            var seen = Set(local.map(\.url))
            var merged = local
            if let spotlight = spotlightService {
                for url in spotlight.results where !seen.contains(url) {
                    if let it = FileItem.from(url: url) {
                        merged.append(it)
                        seen.insert(url)
                    }
                }
            }
            base = sorted(merged)
        }
        // Filter chips only kick in once the user has set at least one
        // — most folders the user opens shouldn't pay for the predicate
        // chain on every cell update.
        guard hasActiveSearchFilter else { return base }
        return base.filter {
            matchesKindFilter($0)
                && matchesSizeFilter($0)
                && matchesDateFilter($0)
        }
    }

    // MARK: - Filter predicates

    private func matchesKindFilter(_ item: FileItem) -> Bool {
        switch searchKindFilter {
        case .all: return true
        case .folder: return item.isDirectory && !item.isPackage
        default:
            // Reuse GroupKey.type's bucketing logic so "Image" / "Video"
            // / etc. mean exactly the same thing in both places.
            return GroupKey.type.bucket(for: item) == searchKindFilter.rawValue
        }
    }

    private func matchesSizeFilter(_ item: FileItem) -> Bool {
        switch searchSizeFilter {
        case .all: return true
        default:
            // Folders fall outside every size bucket — we don't know
            // their size without a recursive scan. Skip when a size
            // filter is active.
            if item.isDirectory && !item.isPackage { return false }
            let bytes = item.size ?? 0
            switch searchSizeFilter {
            case .tiny:   return bytes < 102_400
            case .small:  return bytes < 1_048_576
            case .medium: return bytes < 16_777_216
            case .large:  return bytes < 134_217_728
            case .huge:   return bytes >= 134_217_728
            default: return true
            }
        }
    }

    private func matchesDateFilter(_ item: FileItem) -> Bool {
        switch searchDateFilter {
        case .all: return true
        default:
            guard let date = item.dateModified else { return false }
            let cal = Calendar.current
            let now = Date()
            switch searchDateFilter {
            case .today:      return cal.isDateInToday(date)
            case .yesterday:  return cal.isDateInYesterday(date)
            case .lastWeek:
                let cutoff = cal.date(byAdding: .day, value: -7, to: now) ?? now
                return date >= cutoff
            case .lastMonth:
                let cutoff = cal.date(byAdding: .day, value: -30, to: now) ?? now
                return date >= cutoff
            case .thisYear:
                return cal.component(.year, from: date) == cal.component(.year, from: now)
            default: return true
            }
        }
    }

    /// Snapshot of `searchQuery` after a tag-search seed so a follow-up
    /// `searchQueryChanged()` knows not to clobber the live tag query
    /// with a filename query. Any user-driven edit changes the field
    /// to something else and clears the snapshot.
    private var tagSearchSnapshot: String? = nil

    /// Called whenever `searchQuery` or `searchScope` changes. Starts /
    /// stops the Spotlight query so it stays in sync.
    ///
    /// Both scopes now drive a Spotlight query — `.folder` scopes it to
    /// the current URL so subdirectory matches come back (Windows
    /// Explorer's default behaviour), and `.thisMac` scopes it across
    /// the whole indexed system. The in-memory `items.filter(...)` pass
    /// is still done in `visibleItems` so direct-child matches show
    /// instantly while Spotlight catches up with deeper results.
    private func searchQueryChanged() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // If we're in tag mode and the field still matches the seeded
        // tag name, leave the live tag query alone.
        if let snap = tagSearchSnapshot, snap == searchQuery {
            return
        }
        tagSearchSnapshot = nil   // any divergence exits tag mode

        if q.isEmpty {
            spotlightService?.stop()
            spotlightService = nil
            spotlightForwarder = nil
            return
        }

        if spotlightService == nil {
            let s = SpotlightSearchService()
            spotlightService = s
            spotlightForwarder = s.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        let scopeURL: URL? = (searchScope == .folder) ? currentURL : nil
        spotlightService?.search(q, scope: scopeURL)
    }

    /// Convenience for the ⌘⇧F shortcut — flip into global mode and
    /// keep whatever the user has typed.
    func switchToGlobalSearch() {
        searchScope = .thisMac
    }

    /// Spin up a global Spotlight query for files carrying `tagName`.
    /// Sidebar Tags entries call this — selecting "Red" effectively
    /// turns the file list into "all Red-tagged files on this Mac",
    /// using Spotlight's `kMDItemUserTags` index for the match.
    func searchByTag(_ tagName: String) {
        resetSearchFilters()
        // Provision the spotlight wrapper before switching scope so
        // `searchQueryChanged()` finds something to re-use.
        if spotlightService == nil {
            let s = SpotlightSearchService()
            spotlightService = s
            spotlightForwarder = s.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        // Stash snapshot BEFORE the scope change, and suppress the
        // scope's didSet so it doesn't immediately clear it. Without
        // both, the chain would be:
        //   1. scope=.thisMac → didSet clears snapshot, fires
        //      searchQueryChanged → spotlight starts a filename query
        //      on a stale `searchQuery`
        //   2. snapshot = tagName, searchQuery = tagName → didSet sees
        //      snap == query → early return (but the filename query
        //      from step 1 is still alive)
        //   3. spotlight.searchByTag overwrites — but step 1's query
        //      already churned the UI for one render.
        tagSearchSnapshot = tagName
        suppressScopeReset = true
        searchScope = .thisMac
        suppressScopeReset = false
        searchQuery = tagName
        spotlightService?.searchByTag(tagName, scope: nil)
    }

    /// Reset to local folder search when the user dismisses search.
    func resetSearch() {
        searchScope = .folder
        searchQuery = ""
        resetSearchFilters()
    }

    // MARK: Open

    /// Default-open the current selection. Files launch in their
    /// associated app; the first directory in **visible** order takes
    /// the tab into itself. Walking the visible order (not the sorted
    /// path order we used before) means the "first dir" is the one
    /// closest to the top of the user's list — predictable when they
    /// hit Enter on a mixed selection.
    func openSelected() {
        let selected = Set(selectedURLs)
        let ordered = visibleItems.filter { selected.contains($0.url) }
        var firstDir: URL?
        for item in ordered {
            if FileSystemService.isReadableDirectory(item.url) {
                if firstDir == nil { firstDir = item.url }
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
        if let dir = firstDir {
            navigate(to: dir)
        }
    }

    // MARK: Duplicate

    /// Finder's ⌘D — copy each selected item next to itself, then
    /// select the duplicates so the user can immediately rename them.
    func duplicateSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        do {
            // `var` so redo can re-capture the freshly-made copies —
            // a re-duplicate produces new "copy 2" URLs, and undo must
            // trash *those*, not the original (now-trashed) set.
            var created = try FileOperationService.duplicate(urls)
            reload()
            selectedIDs = Set(created)
            selectionAnchor = created.first
            // Undo a duplicate by trashing the new copies (NOT
            // permanent-delete — keeps an out for the user if they
            // change their mind again). Redo re-duplicates.
            recordUndoable(
                actionName: "Duplicate",
                undo: { [weak self] in
                    _ = FileOperationService.moveToTrash(created)
                    self?.reload()
                },
                redo: { [weak self] in
                    if let again = try? FileOperationService.duplicate(urls) {
                        created = again
                    }
                    self?.reload()
                }
            )
        } catch {
            reportOpError(error.localizedDescription)
            reload()
        }
    }

    // MARK: New folder

    func createNewFolder() {
        do {
            var url = try FileOperationService.createNewFolder(in: currentURL)
            reload()
            // Pre-select + put it into rename mode so the user can type a name.
            selectedIDs = [url]
            renamingItemID = url
            // Undo trashes the created folder; redo re-creates and
            // re-captures the new URL so a following undo trashes the
            // right one (auto-numbering may differ).
            let parent = currentURL
            recordUndoable(
                actionName: "New Folder",
                undo: { [weak self] in
                    _ = FileOperationService.moveToTrash([url])
                    self?.reload()
                },
                redo: { [weak self] in
                    if let again = try? FileOperationService.createNewFolder(in: parent) {
                        url = again
                    }
                    self?.reload()
                }
            )
        } catch {
            reportOpError(error.localizedDescription)
        }
    }

    /// Create an empty file from a built-in template (plain text only
    /// for now). Pre-selects + opens inline rename, same as new folder.
    func createNewFile(baseName: String, extension ext: String, contents: Data? = nil) {
        do {
            var url = try FileOperationService.createNewFile(
                in: currentURL,
                baseName: baseName,
                extension: ext,
                contents: contents
            )
            reload()
            selectedIDs = [url]
            renamingItemID = url
            let parent = currentURL
            recordUndoable(
                actionName: "New File",
                undo: { [weak self] in
                    _ = FileOperationService.moveToTrash([url])
                    self?.reload()
                },
                redo: { [weak self] in
                    if let again = try? FileOperationService.createNewFile(
                        in: parent, baseName: baseName,
                        extension: ext, contents: contents
                    ) {
                        url = again
                    }
                    self?.reload()
                }
            )
        } catch {
            reportOpError(error.localizedDescription)
        }
    }

    // MARK: Rename

    func beginRenameSelected() {
        guard let url = selectedURLs.first else { return }
        renamingItemID = url
    }

    func commitRename(_ url: URL, to newName: String) {
        // Stamp the end-of-rename time on EVERY exit path (incl. the
        // extension-change alert and the error path) so the dismissing
        // click can't re-arm a slow-click rename. `defer` runs after the
        // modal returns, i.e. right before the queued mouseUp is handled.
        defer { lastRenameEndedAt = Date() }
        // Finder-style extension-change guard: if the user altered a
        // file's extension, confirm — and let them keep the original.
        // Returns the (possibly adjusted) name to actually apply, or
        // nil if the rename should be abandoned.
        guard let resolvedName = resolveExtensionChange(for: url, proposed: newName) else {
            renamingItemID = nil
            return
        }
        let newName = resolvedName
        do {
            let oldName = url.lastPathComponent
            let newURL = try FileOperationService.rename(url, to: newName)
            renamingItemID = nil
            reload()
            selectedIDs = [newURL]
            // Capture the old name so undo can rename back. We track
            // URLs across undo/redo with a mutable pair so chained
            // undo↔redo cycles continue to work.
            var current = (from: url, to: newURL, oldName: oldName, newName: newName)
            recordUndoable(
                actionName: "Rename",
                undo: { [weak self] in
                    guard let restored = try? FileOperationService.rename(current.to,
                                                                          to: current.oldName) else { return }
                    current = (from: current.to, to: restored,
                               oldName: current.newName, newName: current.oldName)
                    self?.reload()
                    self?.selectedIDs = [restored]
                },
                redo: { [weak self] in
                    guard let reapplied = try? FileOperationService.rename(current.to,
                                                                           to: current.oldName) else { return }
                    current = (from: current.to, to: reapplied,
                               oldName: current.newName, newName: current.oldName)
                    self?.reload()
                    self?.selectedIDs = [reapplied]
                }
            )
        } catch {
            reportOpError(error.localizedDescription)
            renamingItemID = nil
        }
    }

    /// Finder's "Are you sure you want to change the extension?" guard.
    /// Returns the name to apply: the proposed name when there's no
    /// extension change (or the user confirms it), the proposed stem
    /// re-joined with the ORIGINAL extension when they choose "Keep",
    /// or nil if they cancel out of the alert entirely.
    private func resolveExtensionChange(for url: URL, proposed: String) -> String? {
        // Only files — folders don't carry meaningful extensions, and a
        // folder literally named "My.archive" shouldn't trigger this.
        if FileSystemService.isReadableDirectory(url) { return proposed }

        let oldExt = url.pathExtension
        let newExt = (proposed as NSString).pathExtension
        // No original extension, or unchanged (case-insensitive) → no
        // prompt. Adding an extension where there was none is allowed
        // silently, matching Finder.
        guard !oldExt.isEmpty,
              oldExt.lowercased() != newExt.lowercased() else { return proposed }

        let alert = NSAlert()
        if newExt.isEmpty {
            alert.messageText = "Are you sure you want to remove the extension “.\(oldExt)”?"
        } else {
            alert.messageText = "Are you sure you want to change the extension from “.\(oldExt)” to “.\(newExt)”?"
        }
        alert.informativeText = "If you make this change, your file may open in a different application."
        // First button is the default (Return) — Finder defaults to
        // keeping the original extension, the safe choice.
        alert.addButton(withTitle: "Keep “.\(oldExt)”")
        alert.addButton(withTitle: newExt.isEmpty ? "Remove" : "Use “.\(newExt)”")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Keep original extension: proposed stem + ".oldExt".
            let stem = (proposed as NSString).deletingPathExtension
            return stem.isEmpty ? proposed : "\(stem).\(oldExt)"
        case .alertSecondButtonReturn:
            return proposed   // use the new extension (or remove it)
        default:
            return nil        // shouldn't happen with two buttons
        }
    }

    func cancelRename() {
        renamingItemID = nil
        lastRenameEndedAt = Date()
    }

    // MARK: Trash / delete

    func moveSelectedToTrash() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let trashed = FileOperationService.moveToTrash(urls)
        let failedCount = urls.count - trashed.count
        if trashed.isEmpty {
            reportOpError("No items could be moved to Trash (permission?).")
        } else {
            // Surface partial failure — previously a 2-of-5 failure was
            // silent and looked like the command half-worked.
            if failedCount > 0 {
                reportOpError("\(failedCount) item\(failedCount == 1 ? "" : "s") couldn't be moved to Trash (permission or in use).")
            }
            // Capture the (original, trashed) pairs so undo can pull
            // the items back out of Trash to where they came from.
            // Items that couldn't be resolved to a trash URL (rare
            // FS edge case) are dropped from the undo list — we
            // can't restore what we can't locate.
            // `var` (not `let`) so the redo closure can write the fresh
            // trash URLs back — both closures capture the SAME variable,
            // so a re-trash updates what the next undo restores.
            var restorable = trashed.compactMap { pair -> (original: URL, trashed: URL)? in
                guard let t = pair.trashed else { return nil }
                return (pair.original, t)
            }
            if !restorable.isEmpty {
                recordUndoable(
                    actionName: "Move to Trash",
                    undo: { [weak self] in
                        var failures = 0
                        for pair in restorable {
                            // Re-create the original parent in case it
                            // was deleted/renamed after trashing —
                            // otherwise moveItem throws and the file is
                            // stranded in Trash.
                            let parent = pair.original.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(
                                at: parent, withIntermediateDirectories: true)
                            do {
                                try FileManager.default.moveItem(at: pair.trashed,
                                                                 to: pair.original)
                            } catch {
                                failures += 1
                            }
                        }
                        // Surface partial failure rather than swallowing
                        // it — a silent "⌘Z did nothing" looks like data
                        // loss to the user.
                        if failures > 0 {
                            self?.reportOpError("Couldn't restore \(failures) item\(failures == 1 ? "" : "s") from Trash (original location unavailable).")
                        }
                        self?.reload()
                    },
                    redo: { [weak self] in
                        // Re-trash the originals. macOS may append "2",
                        // "3" on name collision, so re-capture the new
                        // trash URLs into `restorable` for the next undo.
                        // Entries that fail to re-trash keep their PREVIOUS
                        // (original, trashed) pair so a later undo can
                        // still try to restore them — dropping them would
                        // silently orphan the item.
                        var updated: [(original: URL, trashed: URL)] = []
                        var failures = 0
                        for pair in restorable {
                            var result: NSURL?
                            do {
                                try FileManager.default.trashItem(at: pair.original,
                                                                  resultingItemURL: &result)
                                if let t = result as URL? {
                                    updated.append((pair.original, t))
                                } else {
                                    updated.append(pair)   // keep last-known
                                }
                            } catch {
                                updated.append(pair)        // keep last-known
                                failures += 1
                            }
                        }
                        restorable = updated
                        if failures > 0 {
                            self?.reportOpError("Couldn't move \(failures) item\(failures == 1 ? "" : "s") back to Trash.")
                        }
                        self?.reload()
                    }
                )
            }
        }
        reload()
    }

    /// Permanent delete — caller must already have shown a confirmation.
    /// Continues through partial failures (consistent with moveToTrash);
    /// surfaces any per-item errors in `errorMessage`.
    func permanentlyDeleteSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        let errors = FileOperationService.permanentlyDelete(urls)
        if !errors.isEmpty {
            let preview = errors.prefix(5).joined(separator: "\n")
            let extra = errors.count > 5 ? "\n…and \(errors.count - 5) more." : ""
            reportOpError(preview + extra)
        }
        reload()
    }

    // MARK: Paste (Cut/Copy → here)

    func paste() {
        // Resolves to the internal clipboard when the system pasteboard
        // still holds what WE wrote (preserving Cut = move semantics),
        // or to file URLs another app (Finder…) copied since. nil when
        // neither offers files.
        guard let contents = ClipboardService.shared.resolvePasteContents() else { return }
        guard !hasActiveTransfer else {
            reportOpError("Another file operation is in progress. Wait for it to finish.")
            return
        }
        let urls = contents.urls
        let move = contents.move
        let destination = currentURL

        let progress = FileOperationProgress()
        beginTransferSheet(progress)

        // App-modal conflict prompt (NSAlert) — floats above the
        // progress sheet. The previous sheet-based resolver couldn't
        // present over the progress sheet, hanging same-folder pastes.
        // `transfer()` caches the "Apply to All" answer internally, so
        // we don't need the old batchBlanketDecision plumbing here.
        let resolver = ConflictPrompt.resolver()

        let start = Date()
        let count = urls.count
        let verb = move ? "moved" : "copied"
        Task.detached(priority: .userInitiated) {
            let pairs = await FileOperationService.transfer(
                urls,
                to: destination,
                move: move,
                progress: progress,
                resolver: resolver
            )
            let elapsed = Date().timeIntervalSince(start)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if move { ClipboardService.shared.clear() }
                self.reload()
                self.finishTransferSheet(progress)
                self.recordTransferUndo(pairs, move: move)
                NotificationService.notifyOperationCompleted(
                    title: "\(verb.capitalized) \(count) item\(count == 1 ? "" : "s")",
                    body: destination.lastPathComponent,
                    elapsed: elapsed,
                    tab: self
                )
            }
        }
    }

    func dismissTransferDialog() {
        transferProgress = nil
        transferDialogVisible = false
    }

    /// Shared Undo/Redo wiring for `paste()` and `transferDropped()`.
    /// `pairs` are the (source, actual-destination) results FileOperation-
    /// Service.transfer reports — actual because "Keep Both" conflicts
    /// resolve to a uniquified path, not the naive
    /// `destinationFolder/source.lastPathComponent` guess. Items whose
    /// conflict was resolved as "Replace" are already excluded by
    /// `transfer` itself (see its doc comment) since reversing those
    /// would need to also restore whatever they overwrote.
    private func recordTransferUndo(_ pairs: [(source: URL, destination: URL)], move: Bool) {
        guard !pairs.isEmpty else { return }
        recordUndoable(
            actionName: move ? "Move" : "Copy",
            undo: { [weak self] in
                guard let self else { return }
                if move {
                    // Reverse the move: destination back to source.
                    // Recreate the original parent in case it was
                    // itself removed/renamed since — same defensive
                    // pattern as Trash-restore below.
                    for pair in pairs {
                        let parent = pair.source.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(
                            at: parent, withIntermediateDirectories: true)
                        try? FileManager.default.moveItem(at: pair.destination, to: pair.source)
                    }
                } else {
                    // Reverse a copy by trashing the fresh copy it made
                    // — NOT permanent-delete, matching Duplicate/New
                    // Folder/New File's undo, so the user has an out if
                    // they change their mind again after undoing.
                    _ = FileOperationService.moveToTrash(pairs.map(\.destination))
                }
                self.reload()
            },
            redo: { [weak self] in
                guard let self else { return }
                for pair in pairs {
                    let parent = pair.destination.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(
                        at: parent, withIntermediateDirectories: true)
                    if move {
                        try? FileManager.default.moveItem(at: pair.source, to: pair.destination)
                    } else {
                        try? FileManager.default.copyItem(at: pair.source, to: pair.destination)
                    }
                }
                self.reload()
            }
        )
    }

    // MARK: Batch rename

    /// Apply a batch rename plan from BatchRenameDialog. `mapping`
    /// keys are the original URLs; values are the new last-path
    /// components.
    ///
    /// Done in two passes because `[URL: String]` has no defined order
    /// and a chain like A→B, B→C blows up if processed B→C-first
    /// (target taken) or A→B-first (B no longer exists when we get to
    /// the second rename). Renaming everything to a unique temp name
    /// first eliminates that dependency.
    func applyBatchRename(_ mapping: [URL: String]) {
        guard !hasActiveTransfer else {
            reportOpError("Another file operation is in progress. Wait for it to finish.")
            return
        }
        // Drive a progress sheet — a 200-file rename used to freeze the
        // main thread for several seconds while every `moveItem` ran
        // synchronously. The 2-pass logic moves to a detached task so
        // the UI stays responsive and the user gets a live counter.
        let progress = FileOperationProgress()
        progress.total = mapping.count * 2
        progress.currentFileName = "Renaming…"
        beginTransferSheet(progress)

        Task.detached(priority: .userInitiated) {
            var tempMap: [(original: URL, temp: URL, finalName: String)] = []
            var errors: [String] = []

            // Pass 1: stage every source under a UUID temp name so the
            // final targets become free regardless of ordering.
            for (url, newName) in mapping {
                let tempName = ".__fe_rename_\(UUID().uuidString)"
                do {
                    let tempURL = try FileOperationService.rename(url, to: tempName)
                    tempMap.append((original: url, temp: tempURL, finalName: newName))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                await MainActor.run {
                    progress.processed += 1
                    progress.currentFileName = url.lastPathComponent
                }
            }

            // Pass 2: temp → final.
            for entry in tempMap {
                do {
                    _ = try FileOperationService.rename(entry.temp, to: entry.finalName)
                } catch {
                    errors.append("\(entry.original.lastPathComponent) → \(entry.finalName): \(error.localizedDescription)")
                    // Roll back to the original visible name — otherwise
                    // the file is stranded under the hidden `.__fe_rename`
                    // temp name and vanishes from the listing.
                    _ = try? FileOperationService.rename(entry.temp, to: entry.original.lastPathComponent)
                }
                await MainActor.run {
                    progress.processed += 1
                    progress.currentFileName = entry.finalName
                }
            }

            // Snapshot the final error list before the @Sendable hand-
            // off so Swift 6 strict concurrency doesn't complain about
            // a captured `var` crossing actor boundaries.
            let finalErrors = errors
            await MainActor.run { [weak self, finalErrors] in
                guard let self = self else { return }
                if !finalErrors.isEmpty {
                    let preview = finalErrors.prefix(5).joined(separator: "\n")
                    let extra = finalErrors.count > 5 ? "\n…and \(finalErrors.count - 5) more." : ""
                    self.reportOpError(preview + extra)
                    progress.errorMessage = preview + extra
                }
                progress.isDone = true
                self.reload()
                self.finishTransferSheet(progress)
            }
        }
    }

    // MARK: Archive ops

    /// Compress the current selection into a .zip alongside the items.
    func compressSelection() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        guard !hasActiveTransfer else {
            reportOpError("Another file operation is in progress. Wait for it to finish.")
            return
        }
        let progress = FileOperationProgress()
        beginTransferSheet(progress)
        Task.detached(priority: .userInitiated) {
            await ArchiveService.compress(urls, progress: progress)
            await MainActor.run { [weak self] in
                self?.reload()
                self?.finishTransferSheet(progress)
            }
        }
    }

    /// Extract every selected archive into its containing folder.
    /// Supports `.zip`, `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz`,
    /// `.tar.xz`/`.txz`. ArchiveService handles the dispatch.
    func extractSelection() {
        let supportedSuffixes = [".zip", ".tar", ".tar.gz", ".tgz",
                                  ".tar.bz2", ".tbz", ".tar.xz", ".txz"]
        let urls = selectedURLs.filter { url in
            let name = url.lastPathComponent.lowercased()
            return supportedSuffixes.contains { name.hasSuffix($0) }
        }
        guard !urls.isEmpty else { return }
        guard !hasActiveTransfer else {
            reportOpError("Another file operation is in progress. Wait for it to finish.")
            return
        }
        let progress = FileOperationProgress()
        beginTransferSheet(progress)
        Task.detached(priority: .userInitiated) {
            for url in urls {
                await ArchiveService.extract(url, progress: progress)
            }
            await MainActor.run { [weak self] in
                self?.reload()
                self?.finishTransferSheet(progress)
            }
        }
    }

    // MARK: Drag-and-drop entry

    /// Override knob for the drop callback so the user can force a
    /// copy or a move regardless of same/cross-volume default. Read
    /// by `transferDropped(_:to:mode:)` at the moment of drop.
    enum DropMode {
        case auto    // same-volume → move, cross-volume → copy
        case copy    // ⌥ held — always copy
        case move    // ⌘ held — always move
    }

    /// Called by the file list / sidebar when a drop lands. Mirrors
    /// Windows Explorer's default: same-volume → move, cross-volume →
    /// copy. ⌥/⌘ at drop time forces the opposite via `mode`.
    func transferDropped(_ sources: [URL], to destination: URL, mode: DropMode = .auto) {
        // Expand a single-item gesture-view drag back into the multi-
        // selection it represented — SwiftUI's .onDrag can only put ONE
        // item into a drag session, so Icons/Compact/Grouped register
        // the full selection in DragSessionRegistry at drag start.
        // Multi-item drags (Details native drag, Finder) pass through.
        var sources = DragSessionRegistry.shared.expand(sources)
        // Re-filter after expansion: callers only same-folder-filtered
        // the GRABBED item; expanded members may already live in (or BE)
        // the destination.
        sources = sources.filter {
            $0 != destination && $0.deletingLastPathComponent() != destination
        }
        guard !sources.isEmpty else { return }
        guard !hasActiveTransfer else {
            reportOpError("Another file operation is in progress. Wait for it to finish.")
            return
        }
        let move: Bool
        switch mode {
        case .auto: move = sameVolume(sources, destination)
        case .copy: move = false
        case .move: move = true
        }
        let progress = FileOperationProgress()
        beginTransferSheet(progress)

        let resolver = ConflictPrompt.resolver()

        Task.detached(priority: .userInitiated) {
            let pairs = await FileOperationService.transfer(
                sources, to: destination, move: move,
                progress: progress, resolver: resolver
            )
            await MainActor.run { [weak self] in
                self?.reload()
                self?.finishTransferSheet(progress)
                self?.recordTransferUndo(pairs, move: move)
            }
        }
    }

    /// Resource-key based volume comparison — if any source lives on a
    /// different volume than the destination, treat the whole batch as a
    /// copy. Windows Explorer uses this same all-or-nothing rule.
    private func sameVolume(_ urls: [URL], _ destination: URL) -> Bool {
        let destVol = (try? destination.resourceValues(forKeys: [.volumeURLKey]))?.volume
        for src in urls {
            let srcVol = (try? src.resourceValues(forKeys: [.volumeURLKey]))?.volume
            if srcVol != destVol { return false }
        }
        return true
    }
}

