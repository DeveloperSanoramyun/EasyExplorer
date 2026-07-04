//
//  RowInteraction.swift
//  FileExplorer
//
//  Single source of truth for what a click on a file row/tile does, so
//  the three gesture-based views (Compact List / Grouped / Icons) all
//  behave identically instead of each carrying its own near-duplicate
//  copy. The Details view can't share this — SwiftUI's `Table` has no
//  per-row tap callback — so it has no slow-click rename; use F2 /
//  ⌘Return / right-click → Rename there instead.
//
//  ── The selection-interaction model ───────────────────────────────
//
//  SELECTION (changes what's selected):
//    • plain click          → select only      (selectOnly)
//    • ⇧-click              → extend range     (selectRange)
//    • ⌘-click              → toggle one        (toggleSelection)
//    • arrows / type-ahead  → move selection    (KeyboardHandler)
//    • lasso drag (blank)   → marquee select
//    • Esc                  → clear selection
//
//  ACTIVATION (acts on the selection):
//    • double-click / ⏎     → open
//    • Space                → Quick Look
//    • audio ▶ button       → play preview (also selects the row)
//
//  MUTATION (changes the file):
//    • slow second click    → rename   (this file's `SlowClickRename`)
//    • F2 / ⌘⏎              → rename   (KeyboardHandler / menu)
//    • ⌘C/X/V, ⌘D, ⌦, drag  → clipboard / duplicate / trash / move
//
//  RENAME sub-state (while `tab.renamingItemID != nil`):
//    • ⏎ → commit · Esc → cancel · click-outside-field → commit
//    • every other key is suppressed (KeyboardHandler gates on
//      `renamingItemID == nil`) so typing edits the name, not the list.
//
//  Conflict avoidance:
//    • slow-click rename is armed only when the click landed on the row
//      that was ALREADY the sole selection, and is cancelled by a
//      double-click, a modifier click, selection moving away, or an
//      audio-control tap (`recentlyToggled`).
//    • a folder change or external delete clears `renamingItemID`
//      (TabViewModel.currentURL didSet / reload), so rename can't strand
//      the keyboard.
//

import SwiftUI
import AppKit

/// Per-row folder drop target + light-purple highlight. Owns its OWN
/// `@State` for the hover flag, so a drag entering/leaving one row
/// re-renders only THAT row — not the whole list (which a view-level
/// `@State dropTargetURL` would, making the highlight feel laggy).
///
/// `onDrop` returns whether the drop was accepted. The highlight only
/// shows for folders; files render no highlight and reject the drop.
private struct FolderDropTarget: ViewModifier {
    let isFolder: Bool
    let onDrop: ([URL]) -> Bool
    @State private var targeted = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFolder {
            content
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.purple.opacity(0.18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.purple.opacity(0.65), lineWidth: 1.5)
                            )
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    targeted = false
                    return onDrop(urls)
                } isTargeted: { over in
                    // No animation → the highlight tracks the cursor with
                    // no fade-in lag.
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { targeted = over }
                }
        } else {
            // Files are NOT drop targets — and crucially they must not
            // even REGISTER as one. A registered-but-rejecting target
            // swallows the drag, creating dead zones where dropping on
            // a file row did nothing. Unregistered, the drag falls
            // through to the list-background handler and lands in the
            // current folder, like Finder.
            content
        }
    }
}

extension View {
    /// Attach a folder drop target with the standard purple hover
    /// highlight. `isFolder` gates both the highlight and acceptance.
    func folderDropTarget(isFolder: Bool, onDrop: @escaping ([URL]) -> Bool) -> some View {
        modifier(FolderDropTarget(isFolder: isFolder, onDrop: onDrop))
    }
}

/// Records the selection an in-app drag stands for. A SwiftUI
/// `.onDrag` / `.draggable` can only put ONE item into a drag session,
/// so the gesture views (Icons / Compact / Grouped) register the grabbed
/// item plus the full multi-selection here at drag start; every drop
/// path funnels through `TabViewModel.transferDropped`, which expands
/// the single received URL back into that selection. The Details Table
/// doesn't need this — its native row drag carries all selected rows.
@MainActor
final class DragSessionRegistry {
    static let shared = DragSessionRegistry()
    private var grabbed: URL?
    private var selection: [URL] = []
    private var startedAt: Date = .distantPast

    func begin(grabbed: URL, selection: [URL]) {
        self.grabbed = grabbed
        self.selection = selection
        self.startedAt = Date()
    }

    /// Expand a received single-item drop back into the selection it
    /// represented. CONSUMES the registration either way, so a stale
    /// entry (e.g. from a cancelled drag) can't leak into a later,
    /// unrelated drop. Multi-item drags (Details native drag, Finder)
    /// pass through untouched.
    func expand(_ received: [URL]) -> [URL] {
        defer { grabbed = nil; selection = [] }
        guard received.count == 1,
              let g = grabbed, received[0] == g,
              selection.count > 1,
              Date().timeIntervalSince(startedAt) < 30 else { return received }
        return selection
    }
}

/// Drag source for one gesture-view row/tile: vends the grabbed file's
/// URL and registers the full selection it represents (see
/// DragSessionRegistry). Dragging an UNSELECTED item drags just it —
/// Finder behaviour.
@MainActor
func beginRowDrag(_ url: URL, tab: TabViewModel) -> NSItemProvider {
    let sel = tab.selectedIDs
    let urls: [URL]
    if sel.contains(url), sel.count > 1 {
        // Visible order, not Set order, so the transfer processes items
        // in the order the user sees them.
        urls = tab.visibleItems.map(\.url).filter { sel.contains($0) }
    } else {
        urls = [url]
    }
    DragSessionRegistry.shared.begin(grabbed: url, selection: urls)
    return NSItemProvider(object: url as NSURL)
}

/// Live keyboard modifiers for a click, reduced to the one selection
/// modifier that matters. `onTapGesture` / `simultaneousGesture` don't
/// deliver modifiers, so we sample `NSEvent` at tap time.
@MainActor
func currentSelectionModifiers() -> EventModifiers {
    let m = NSEvent.modifierFlags
    if m.contains(.shift)   { return .shift }
    if m.contains(.command) { return .command }
    return []
}

/// Apply a single click's selection effect, and (for an unmodified
/// click that re-hits the sole selection) arm a Finder-style rename.
/// Shared by Compact / Grouped / Icons so their behaviour can't drift.
@MainActor
func applyRowClick(url: URL,
                   wasSelected: Bool,
                   modifiers: EventModifiers,
                   tab: TabViewModel,
                   slowRename: SlowClickRename) {
    if modifiers.contains(.shift) {
        slowRename.cancel()
        tab.selectRange(to: url)
        return
    }
    if modifiers.contains(.command) {
        slowRename.cancel()
        tab.toggleSelection(url)
        return
    }
    let wasSoleSelection = wasSelected && tab.selectedIDs.count == 1
    tab.selectOnly(url)
    slowRename.arm(url, wasSoleSelection: wasSoleSelection, tab: tab)
}

/// Holds the pending "slow second click → rename" timer for one view,
/// plus the small amount of timing state needed to tell a *deliberate*
/// slow re-click apart from the look-alike events that must NOT rename:
///   • the 2nd press of a double-click            → open, not rename
///   • the click that DISMISSES an active rename  → just select
///   • a stray single-tap right after an open     → ignore
///
/// Reference type (not a `@State` tuple captured in a closure) so the
/// timer can be cancelled / re-armed reliably; held as `@State` by each
/// view, which keeps one stable instance across re-renders. This mirrors
/// the Details `TableRenameClickDetector` so every view mode behaves the
/// same. Each guard is *additive* — it only ever SUPPRESSES an arm in a
/// known-bad situation, never blocks a genuine deliberate slow click.
@MainActor
final class SlowClickRename {
    private var work: DispatchWorkItem?
    /// (sole-selected URL, when it became sole). Fed from the view's
    /// `.onChange(of: tab.selectedIDs)`. A click only arms a rename when
    /// the row has been the sole selection LONGER than the double-click
    /// window — a fast second click (a double-click) keeps this recent,
    /// so the item opens instead of renaming.
    private var soleSince: (url: URL, at: Date)?
    /// When the last open (double-click) fired. A slow double-click can
    /// register as two single taps; the 2nd tap must not re-arm a rename.
    private var lastOpenAt: Date = .distantPast

    /// Wire from the view's `.onChange(of: tab.selectedIDs)`.
    func selectionChanged(_ sel: Set<URL>) {
        if sel.count == 1, let only = sel.first {
            if soleSince?.url != only { soleSince = (only, Date()) }
        } else {
            soleSince = nil
        }
    }

    /// Wire from the view's `.onChange(of: tab.renamingItemID)`. Cancels
    /// any pending arm and pushes the sole-selection clock forward so the
    /// click that just dismissed a rename can't immediately re-arm one on
    /// the same row (belt-and-suspenders with `tab.renameRecentlyEnded`).
    func renameDidChange() {
        cancel()
        if let s = soleSince { soleSince = (s.url, Date()) }
    }

    /// Call from the double-click handler (alongside `cancel()`) so a
    /// stray single-tap from the same double-click can't re-arm a rename.
    func noteOpened() { lastOpenAt = Date() }

    /// Arm after the standard pause. Call AFTER updating selection.
    /// No-op unless this is a genuine deliberate slow re-click.
    func arm(_ url: URL, wasSoleSelection: Bool, tab: TabViewModel) {
        cancel()
        guard wasSoleSelection else { return }
        // Not the 2nd press of a double-click that just opened …
        guard Date().timeIntervalSince(lastOpenAt) > NSEvent.doubleClickInterval else { return }
        // … not the click that just dismissed a rename …
        guard !tab.renameRecentlyEnded else { return }
        // … and not a freshly-formed sole selection (a double-click in
        // progress). Only blocks when we positively know it's fresh; an
        // unknown / older selection falls through and arms as before.
        if let sole = soleSince, sole.url == url,
           Date().timeIntervalSince(sole.at) < NSEvent.doubleClickInterval {
            return
        }
        let work = DispatchWorkItem { [weak tab] in
            guard let tab else { return }
            guard tab.selectedIDs == [url], tab.renamingItemID == nil else { return }
            // Don't rename mid-drag (a button is still physically held)
            // or when the click really targeted the row's audio ▶ control.
            guard NSEvent.pressedMouseButtons == 0,
                  !AudioPreviewService.shared.recentlyToggled(url) else { return }
            tab.renamingItemID = url
        }
        self.work = work
        // 0.6 s ≈ the macOS double-click window plus a margin, so a
        // deliberate slow second click renames without racing the
        // system's double-click detection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

// MARK: - Shared row/tile behaviors (Icons / Compact / Grouped)
//
// Everything below used to be near-verbatim duplicated in all three
// gesture-based views. Consolidated here after a full-project audit ahead
// of the initial GitHub push. None of this touches @State directly —
// mutable pieces come in as `Binding`s supplied by the calling view's own
// `@State`, which is safe because each caller rebuilds its Gesture/View
// value fresh on every `body` evaluation (unlike the long-lived NSEvent
// monitors elsewhere in this file, which DO need the class-based
// workaround for SwiftUI's @State-capture trap).

/// Open a file (its default app) or navigate into a folder. Shared by
/// every gesture-based view's double-click handler AND their "Open"
/// context-menu item, which used to each carry their own copy.
@MainActor
func openFileListEntry(_ url: URL, tab: TabViewModel) {
    if FileSystemService.isReadableDirectory(url) {
        tab.navigate(to: url)
    } else {
        NSWorkspace.shared.open(url)
    }
}

/// Promote a right-clicked / drop-targeted row to the selection when it
/// wasn't already part of a multi-selection — same rule Finder/Explorer
/// use so a context-menu action or Cut/Copy acts on the row you clicked,
/// not a stale prior selection.
@MainActor
func ensureFileListSelection(includes url: URL, tab: TabViewModel) {
    if !tab.selectedIDs.contains(url) {
        tab.selectedIDs = [url]
    }
}

/// Read live modifier keys to decide a drop's transfer mode. ⌥ forces
/// copy, ⌘ forces move; otherwise `transferDropped` applies the
/// same-volume-moves/cross-volume-copies default.
@MainActor
func fileListDropMode() -> TabViewModel.DropMode {
    let mods = NSEvent.modifierFlags
    if mods.contains(.option) { return .copy }
    if mods.contains(.command) { return .move }
    return .auto
}

/// Move/copy items dropped onto a folder ROW (not the list background).
/// Refuses a folder dropped onto itself; everything else routes through
/// `TabViewModel.transferDropped`.
@discardableResult
@MainActor
func fileListDropInto(_ folder: URL, dropped: [URL], tab: TabViewModel) -> Bool {
    guard FileSystemService.isReadableDirectory(folder) else { return false }
    let sources = dropped.filter { $0 != folder && $0.deletingLastPathComponent() != folder }
    guard !sources.isEmpty else { return false }
    tab.transferDropped(sources, to: folder, mode: fileListDropMode())
    return true
}

/// Move/copy items dropped onto the list's blank BACKGROUND — lands in
/// the tab's current folder. Kept separate from `fileListDropInto`
/// (rather than calling it with `tab.currentURL`) because the exclusion
/// filter differs slightly: a background drop only needs to reject items
/// already living in the current folder, not the `$0 != folder`
/// self-drop check a folder ROW target needs.
@discardableResult
@MainActor
func fileListDropIntoCurrentFolder(_ droppedURLs: [URL], tab: TabViewModel) -> Bool {
    let sources = droppedURLs.filter { $0.deletingLastPathComponent() != tab.currentURL }
    guard !sources.isEmpty else { return false }
    tab.transferDropped(sources, to: tab.currentURL, mode: fileListDropMode())
    return true
}

/// Invisible GeometryReader planted behind a row/tile to publish its
/// on-screen frame (in the "lasso" named coordinate space) for marquee
/// hit-testing. Pure — doesn't touch `tab` or any view's `@State`.
func lassoFrameReporter(for url: URL) -> some View {
    GeometryReader { proxy in
        Color.clear.preference(
            key: ItemFramePreferenceKey.self,
            value: [url: proxy.frame(in: .named("lasso"))]
        )
    }
}

/// Marquee (lasso) selection drag gesture, shared by Icons / Compact /
/// Grouped. Called fresh from each view's `.gesture(...)` on every `body`
/// evaluation — exactly like the per-view methods it replaces — so the
/// `Binding`s below always resolve to that view's CURRENT `@State`
/// storage rather than a stale snapshot.
///
/// `edgeZone` is a parameter (not a shared constant) because Icons used
/// 40pt against the list views' 30pt before this consolidation — kept
/// exactly as each view had it rather than silently picking one.
@MainActor
func lassoSelectionGesture(
    itemFrames: [URL: CGRect],
    lassoRect: Binding<CGRect?>,
    baseSelection: Binding<Set<URL>>,
    lastAutoScroll: Binding<Date>,
    flatItems: [FileItem],
    edgeZone: CGFloat,
    tab: TabViewModel,
    proxy: ScrollViewProxy
) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named("lasso"))
        .onChanged { value in
            if lassoRect.wrappedValue == nil {
                // First tick of the drag — remember the selection we
                // started with so modifier keys can layer on top of it.
                baseSelection.wrappedValue = tab.selectedIDs
            }
            let rect = CGRect(
                x: min(value.startLocation.x, value.location.x),
                y: min(value.startLocation.y, value.location.y),
                width: abs(value.location.x - value.startLocation.x),
                height: abs(value.location.y - value.startLocation.y)
            )
            lassoRect.wrappedValue = rect

            var hits: Set<URL> = []
            for (url, frame) in itemFrames where rect.intersects(frame) {
                hits.insert(url)
            }

            // Read modifiers live — DragGesture doesn't pass them.
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                tab.selectedIDs = baseSelection.wrappedValue.symmetricDifference(hits)
            } else if mods.contains(.shift) {
                tab.selectedIDs = baseSelection.wrappedValue.union(hits)
            } else {
                tab.selectedIDs = hits
            }

            lassoAutoScrollIfNeeded(
                value: value, proxy: proxy, itemFrames: itemFrames,
                flatItems: flatItems, edgeZone: edgeZone,
                lastAutoScroll: lastAutoScroll
            )
        }
        .onEnded { _ in
            lassoRect.wrappedValue = nil
            baseSelection.wrappedValue = []
        }
}

/// When the marquee cursor sits near the top/bottom of the visible
/// items, nudge the ScrollView so off-screen items come into hit-test
/// range. Throttled to ~10Hz to avoid overshooting on the gesture's
/// 60fps `onChanged` stream.
@MainActor
private func lassoAutoScrollIfNeeded(
    value: DragGesture.Value,
    proxy: ScrollViewProxy,
    itemFrames: [URL: CGRect],
    flatItems: [FileItem],
    edgeZone: CGFloat,
    lastAutoScroll: Binding<Date>
) {
    guard !itemFrames.isEmpty,
          Date().timeIntervalSince(lastAutoScroll.wrappedValue) > 0.08 else { return }
    let frames = itemFrames.values
    guard let topY = frames.map(\.minY).min(),
          let bottomY = frames.map(\.maxY).max() else { return }

    if value.location.y < topY + edgeZone {
        if let topItem = itemFrames.min(by: { $0.value.minY < $1.value.minY })?.key,
           let idx = flatItems.firstIndex(where: { $0.url == topItem }),
           idx > 0 {
            proxy.scrollTo(flatItems[max(0, idx - 3)].url, anchor: .top)
            lastAutoScroll.wrappedValue = Date()
        }
    } else if value.location.y > bottomY - edgeZone {
        if let bottomItem = itemFrames.max(by: { $0.value.maxY < $1.value.maxY })?.key,
           let idx = flatItems.firstIndex(where: { $0.url == bottomItem }),
           idx < flatItems.count - 1 {
            proxy.scrollTo(flatItems[min(flatItems.count - 1, idx + 3)].url, anchor: .bottom)
            lastAutoScroll.wrappedValue = Date()
        }
    }
}

/// "Open With" submenu for a file — lists every app Launch Services
/// offers as a handler, marks the default, and falls back to a chooser.
/// Shared by every view mode (gesture views + the Details Table) so a
/// launch failure surfaces the same way everywhere.
@ViewBuilder
@MainActor
func openWithFileMenu(for url: URL, tab: TabViewModel) -> some View {
    Menu("Open With") {
        let apps = AppLauncherService.applications(handlerFor: url)
        ForEach(apps) { app in
            Button {
                AppLauncherService.open([url], with: app.url, tab: tab)
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
            AppLauncherService.chooseApplication(for: [url], tab: tab)
        }
    }
}

/// Right-click menu for a single row/tile. Unifies what used to be three
/// near-identical copies — the reconciliation also fixes two real
/// inconsistencies the duplication had let drift apart: Compact List was
/// missing "Rename" entirely (F2 / slow-click still worked, only the
/// menu entry was absent), and both Compact List and Grouped were
/// missing "Open in Terminal" for folders that Icons already had.
@ViewBuilder
@MainActor
func fileListRowContextMenu(for url: URL, tab: TabViewModel) -> some View {
    Button("Open") { openFileListEntry(url, tab: tab) }
    if !FileSystemService.isReadableDirectory(url) {
        openWithFileMenu(for: url, tab: tab)
    }
    Divider()
    Button("Cut") {
        ensureFileListSelection(includes: url, tab: tab)
        ClipboardService.shared.cut(Array(tab.selectedIDs))
    }
    Button("Copy") {
        ensureFileListSelection(includes: url, tab: tab)
        ClipboardService.shared.copy(Array(tab.selectedIDs))
    }
    Button("Paste") { tab.paste() }
        .disabled(!ClipboardService.shared.hasContent)
    Button("Copy Path") {
        ensureFileListSelection(includes: url, tab: tab)
        ClipboardService.copyPathsToPasteboard(Array(tab.selectedIDs))
    }
    Divider()
    Button("Rename") {
        ensureFileListSelection(includes: url, tab: tab)
        tab.beginRenameSelected()
    }
    Button("Move to Trash") {
        ensureFileListSelection(includes: url, tab: tab)
        tab.moveSelectedToTrash()
    }
    Divider()
    if FileSystemService.isReadableDirectory(url) {
        Button("Open in Terminal") { TerminalLauncher.open(url) }
    }
    Button("Show in Finder") {
        ensureFileListSelection(includes: url, tab: tab)
        NSWorkspace.shared.activateFileViewerSelecting(Array(tab.selectedIDs))
    }
    Button("Share…") {
        ensureFileListSelection(includes: url, tab: tab)
        ShareService.showPicker(for: Array(tab.selectedIDs))
    }
}

/// Right-click menu for the list's blank background — identical across
/// all three views except the mode-switch menu in the middle (Icons /
/// Compact show "View", Grouped shows "Group By" since picking a plain
/// view mode there wouldn't make sense while grouped). Callers supply
/// that one differing menu via `modeMenu`.
@ViewBuilder
@MainActor
func fileListBlankContextMenu<ModeMenu: View>(
    tab: TabViewModel,
    @ViewBuilder modeMenu: () -> ModeMenu
) -> some View {
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
    modeMenu()
    Divider()
    Button("Refresh") { tab.reload() }
}
