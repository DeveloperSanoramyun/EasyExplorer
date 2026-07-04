//
//  KeyboardHandler.swift
//  FileExplorer
//
//  Windows-Explorer keyboard behaviours that aren't easy to wire via
//  menu shortcuts:
//
//  • **Type-ahead**: typing letters jumps to the first item whose name
//    starts with the typed string (case-insensitive). Buffer resets
//    after 700 ms of inactivity.
//
//  • **Backspace** (plain ⌫ with no modifier): navigates UP one folder,
//    matching Windows. The modifier-combined ⌘⌫ is reserved for "Move
//    to Trash" via the Edit menu, so the two don't conflict.
//

import SwiftUI

struct KeyboardHandler: ViewModifier {
    @ObservedObject var tab: TabViewModel

    /// On-screen item rectangles (named-coordinate-space) supplied by
    /// grid views so arrow keys can navigate in true 2D. Empty for
    /// list-style views, which fall back to linear ±1 movement.
    var gridFrames: [URL: CGRect] = [:]

    /// Per-view type-ahead buffer + timestamp. Used to live in a class
    /// `static let` which leaked typing state across windows / tabs —
    /// pressing "A" in one window pre-armed the buffer in every other
    /// window. @State makes it window-scoped.
    @State private var typeAheadBuffer: String = ""
    @State private var typeAheadLastKey: Date = .distantPast

    /// macOS function key Unicode mappings — KeyEquivalent doesn't
    /// expose F-keys as named constants the way it does arrow/return,
    /// but onKeyPress accepts any Character produced from the special-
    /// function code points (NSEvent function key constants).
    private static let f2Key = KeyEquivalent(Character(UnicodeScalar(0xF705)!))
    private static let f5Key = KeyEquivalent(Character(UnicodeScalar(0xF708)!))

    func body(content: Content) -> some View {
        content
            .focusable()  // makes the view eligible to receive key events
            .focusEffectDisabled()  // …but hide the accent focus ring
            .onKeyPress(keys: [Self.f2Key], phases: .down) { _ in
                // F2 = Rename — Windows muscle memory. ⌘Return still
                // works via the Edit menu shortcut for Mac users.
                guard tab.renamingItemID == nil else { return .ignored }
                guard !tab.selectedURLs.isEmpty else { return .ignored }
                tab.beginRenameSelected()
                return .handled
            }
            .onKeyPress(keys: [Self.f5Key], phases: .down) { _ in
                // F5 = Refresh — Windows convention. ⌘R from the Go
                // menu is the macOS-side equivalent.
                guard tab.renamingItemID == nil else { return .ignored }
                tab.reload()
                return .handled
            }
            .onKeyPress(keys: [.delete], phases: .down) { press in
                // Plain Backspace = BACK in history — this matches
                // Windows 10/11 (older WinXP used Backspace=Up, but
                // that reflex is long dead). Parent-folder navigation
                // lives on Alt(⌥)+Up and ⌘↑. Modifier-combined presses
                // (⌘⌫ = Trash, ⌘⇧⌫ = Delete) defer to the Edit menu.
                // Skipped during inline rename so Backspace edits text.
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty else { return .ignored }
                tab.goBack()
                return .handled
            }
            // ⌥(Alt)+Up = Up to parent — the Windows reflex now that
            // Backspace is Back. ⌥+Left / ⌥+Right also mirror Windows'
            // Alt+arrow Back/Forward. (⌘[ / ⌘] / ⌘↑ stay as the macOS
            // menu shortcuts.)
            .onKeyPress(keys: [.upArrow], phases: .down) { press in
                guard tab.renamingItemID == nil,
                      press.modifiers.contains(.option) else { return .ignored }
                tab.goUp()
                return .handled
            }
            .onKeyPress(keys: [.leftArrow], phases: .down) { press in
                guard tab.renamingItemID == nil,
                      press.modifiers.contains(.option) else { return .ignored }
                tab.goBack()
                return .handled
            }
            .onKeyPress(keys: [.rightArrow], phases: .down) { press in
                guard tab.renamingItemID == nil,
                      press.modifiers.contains(.option) else { return .ignored }
                tab.goForward()
                return .handled
            }
            .onKeyPress(keys: [.deleteForward], phases: .down) { press in
                // The Mac forward-delete key (⌦, or fn+⌫ on laptops) is
                // what a Windows user reaches for as "Delete" — and in
                // Windows that sends to the Recycle Bin. Shift+Delete =
                // permanent delete (routes through the same confirm
                // dialog the menu uses). Skipped during rename.
                guard tab.renamingItemID == nil else { return .ignored }
                guard !tab.selectedURLs.isEmpty else { return .ignored }
                if press.modifiers.contains(.shift) {
                    NotificationCenter.default.post(
                        name: .feDeleteSelectionPermanently, object: nil)
                } else {
                    tab.moveSelectedToTrash()
                }
                return .handled
            }
            .onKeyPress(keys: [.return], phases: .down) { press in
                // Enter opens the selection — Windows Explorer's default.
                // Modifier combos (⌘Return = Rename) keep their menu
                // shortcuts. BUT — if an inline rename is in flight, we
                // must let the focused TextField commit the new name
                // via its onCommit. Without this guard the parent's
                // Enter handler races the TextField and the file gets
                // opened with the original name instead.
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty,
                      !tab.selectedURLs.isEmpty else { return .ignored }
                tab.openSelected()
                return .handled
            }
            .onKeyPress(.escape) {
                // Esc closes the QuickLook panel if it's open, otherwise
                // clears selection — matches Finder behaviour. Again:
                // skip while renaming so the TextField's onExitCommand
                // can cancel the rename instead of nuking the selection.
                if tab.renamingItemID != nil { return .ignored }
                if QuickLookCoordinator.shared.isOpen {
                    QuickLookCoordinator.shared.close()
                } else {
                    tab.selectedIDs.removeAll()
                }
                return .handled
            }
            .onKeyPress(keys: [.space], phases: .down) { press in
                // Space toggles QuickLook on the current selection.
                // Modifier-combined Space (e.g. ⌥-Space) is reserved
                // for system actions — don't intercept those.
                // IMPORTANT: this handler must be more specific than
                // the catch-all type-ahead below, and we exclude " "
                // from the catch-all's accepted character set so a
                // selection-less Space still drops to QuickLook (which
                // no-ops) rather than typing a space into the buffer.
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty,
                      !tab.selectedURLs.isEmpty else { return .ignored }
                if QuickLookCoordinator.shared.isOpen {
                    QuickLookCoordinator.shared.close()
                } else {
                    QuickLookCoordinator.shared.show(tab.selectedURLs)
                }
                return .handled
            }
            .onKeyPress(keys: [.upArrow], phases: .down) { press in
                // ⌘↑ is "Go Up to parent folder"; ⌥↑ handled above.
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isDisjoint(with: [.command, .option]) else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                if !moveByGeometry(dx: 0, dy: -1, extend: extend) {
                    moveSelection(by: -1, extend: extend)
                }
                return .handled
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { press in
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isDisjoint(with: [.command, .option]) else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                if !moveByGeometry(dx: 0, dy: 1, extend: extend) {
                    moveSelection(by: 1, extend: extend)
                }
                return .handled
            }
            // Left/Right arrows: 2D navigation in grid views (geometry),
            // ignored in list views (so they don't hijack anything).
            // ⌥+Left/Right are Back/Forward, handled above.
            .onKeyPress(keys: [.leftArrow], phases: .down) { press in
                guard tab.renamingItemID == nil,
                      press.modifiers.isDisjoint(with: [.command, .option]) else { return .ignored }
                // Only grid views navigate horizontally; list views let
                // the key pass through. In grid mode, fall back to
                // linear movement when the anchor tile is scrolled
                // off-screen (no frame to compute geometry from).
                guard !gridFrames.isEmpty else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                if !moveByGeometry(dx: -1, dy: 0, extend: extend) {
                    moveSelection(by: -1, extend: extend)
                }
                return .handled
            }
            .onKeyPress(keys: [.rightArrow], phases: .down) { press in
                guard tab.renamingItemID == nil,
                      press.modifiers.isDisjoint(with: [.command, .option]) else { return .ignored }
                guard !gridFrames.isEmpty else { return .ignored }
                let extend = press.modifiers.contains(.shift)
                if !moveByGeometry(dx: 1, dy: 0, extend: extend) {
                    moveSelection(by: 1, extend: extend)
                }
                return .handled
            }
            .onKeyPress(keys: [.home], phases: .down) { press in
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty else { return .ignored }
                jumpToFirst()
                return .handled
            }
            .onKeyPress(keys: [.end], phases: .down) { press in
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty else { return .ignored }
                jumpToLast()
                return .handled
            }
            .onKeyPress(keys: [.pageUp], phases: .down) { press in
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty else { return .ignored }
                movePage(by: -pageSize)
                return .handled
            }
            .onKeyPress(keys: [.pageDown], phases: .down) { press in
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isEmpty else { return .ignored }
                movePage(by: pageSize)
                return .handled
            }
            .onKeyPress(phases: .down) { press in
                // Type-ahead catch-all. Accepts printable characters
                // (letters incl. CJK, digits, plus `_-.`) so real
                // filenames like "Photo_2024" / "한글파일" can match.
                // Pure space is intentionally NOT here — see the
                // Space handler above for QuickLook.
                guard tab.renamingItemID == nil else { return .ignored }
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                    return .ignored
                }
                let chars = press.characters
                guard !chars.isEmpty,
                      chars.unicodeScalars.allSatisfy({ scalar in
                          scalar.properties.isAlphabetic
                              || CharacterSet.decimalDigits.contains(scalar)
                              || CharacterSet(charactersIn: "_-.").contains(scalar)
                      })
                else { return .ignored }
                handleTypeAhead(chars)
                return .handled
            }
    }

    // MARK: - Selection movement

    /// Approximate page step. Real Windows Explorer scales this to the
    /// visible row count, but SwiftUI doesn't expose that for Table /
    /// LazyVGrid so a fixed value is pragmatic — it still moves the
    /// selection in chunks instead of one-at-a-time.
    private var pageSize: Int { 10 }

    /// True 2D arrow navigation for grid views. Finds the nearest item
    /// whose centre lies in the requested direction (dx/dy ∈ {-1,0,1}),
    /// scoring distance along the travel axis with a heavy penalty for
    /// drift on the cross axis — so ↓ lands on the item directly below,
    /// not a diagonal neighbour. Returns false when there are no frames
    /// (list views) or no candidate in that direction, letting the
    /// caller fall back to linear movement / pass the key through.
    private func moveByGeometry(dx: Int, dy: Int, extend: Bool) -> Bool {
        guard !gridFrames.isEmpty else { return false }
        let items = tab.visibleItems
        guard !items.isEmpty else { return false }

        // Pivot off the explicit selection anchor — `selectedIDs.first`
        // is an arbitrary element of an unordered Set, so with a
        // multi-selection it would move from a random tile.
        let anchorURL = tab.selectionAnchor
            ?? tab.selectedIDs.first
            ?? items.first?.url
        guard let anchorURL, let from = gridFrames[anchorURL] else { return false }
        let cx = from.midX, cy = from.midY

        var best: (url: URL, score: CGFloat)?
        for item in items where item.url != anchorURL {
            guard let f = gridFrames[item.url] else { continue }
            let ddx = f.midX - cx
            let ddy = f.midY - cy
            let score: CGFloat
            if dx != 0 {
                // Horizontal travel: candidate must be on the correct side.
                guard (dx > 0 && ddx > 1) || (dx < 0 && ddx < -1) else { continue }
                score = abs(ddx) + abs(ddy) * 3
            } else {
                // Vertical travel.
                guard (dy > 0 && ddy > 1) || (dy < 0 && ddy < -1) else { continue }
                score = abs(ddy) + abs(ddx) * 3
            }
            if best == nil || score < best!.score { best = (item.url, score) }
        }
        guard let target = best?.url else { return false }
        if extend { tab.selectRange(to: target) } else { tab.selectOnly(target) }
        return true
    }

    private func jumpToFirst() {
        guard let first = tab.visibleItems.first else { return }
        tab.selectedIDs = [first.url]
    }

    private func jumpToLast() {
        guard let last = tab.visibleItems.last else { return }
        tab.selectedIDs = [last.url]
    }

    /// One-step ↑/↓ row movement. When `extend` is set (Shift held)
    /// the existing selection grows from the anchor — same convention
    /// as a manual ⇧-click on the new target.
    private func moveSelection(by delta: Int, extend: Bool) {
        let items = tab.visibleItems
        guard !items.isEmpty else { return }
        let anchor: Int
        if let pivot = anchorURL(),
           let idx = items.firstIndex(where: { $0.url == pivot }) {
            anchor = idx
        } else {
            anchor = delta > 0 ? -1 : items.count
        }
        let target = max(0, min(items.count - 1, anchor + delta))
        let targetURL = items[target].url
        if extend {
            tab.selectRange(to: targetURL)
        } else {
            tab.selectOnly(targetURL)
        }
    }

    private func movePage(by delta: Int) {
        let items = tab.visibleItems
        guard !items.isEmpty else { return }
        let anchor: Int
        if let pivot = anchorURL(),
           let idx = items.firstIndex(where: { $0.url == pivot }) {
            anchor = idx
        } else {
            // Nothing selected — start from the top going down, bottom
            // going up. Mirrors Explorer's "first PgDn lands on item 10".
            anchor = delta > 0 ? -1 : items.count
        }
        let target = max(0, min(items.count - 1, anchor + delta))
        tab.selectedIDs = [items[target].url]
    }

    /// The pivot for keyboard movement: the explicit selection anchor,
    /// falling back to an arbitrary selected element. Using the anchor
    /// keeps arrow-stepping deterministic when several items are
    /// selected (a Set has no stable "first").
    private func anchorURL() -> URL? {
        tab.selectionAnchor ?? tab.selectedIDs.first
    }

    // MARK: - Type-ahead implementation

    private func handleTypeAhead(_ characters: String) {
        let now = Date()
        if now.timeIntervalSince(typeAheadLastKey) > 0.7 {
            typeAheadBuffer = ""
        }
        typeAheadLastKey = now
        typeAheadBuffer += characters

        let q = typeAheadBuffer
        guard let match = tab.visibleItems.first(where: {
            $0.name.range(of: q, options: [.caseInsensitive, .anchored]) != nil
        }) else { return }

        tab.selectedIDs = [match.url]
    }
}

extension View {
    /// Attach the Windows-Explorer keyboard behaviours (Backspace=Back,
    /// Delete=Trash, type-ahead, 2D arrow nav, Esc=deselect) to any
    /// view. `gridFrames` is supplied only by grid views to enable
    /// geometry-based 2D arrow navigation; list views omit it.
    func feKeyboardNavigation(tab: TabViewModel,
                              gridFrames: [URL: CGRect] = [:]) -> some View {
        modifier(KeyboardHandler(tab: tab, gridFrames: gridFrames))
    }
}
