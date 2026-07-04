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
