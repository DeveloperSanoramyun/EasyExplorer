//
//  WindowState.swift
//  FileExplorer
//
//  Per-window state — owns the array of tabs, the active tab index, and
//  the stack of recently-closed tabs for ⌘⇧T reopen. Every menu command
//  routes through here so it always lands on the visible tab, even when
//  the user has switched away between issuing the shortcut and the
//  callback firing.
//

import Foundation
import Combine
import AppKit

@MainActor
final class WindowState: ObservableObject {

    @Published var tabs: [TabViewModel]
    @Published var activeIndex: Int = 0

    // MARK: Split (dual-pane) view

    enum PaneSide { case left, right }

    /// Two folders side by side for move/copy between them. The LEFT
    /// pane is the existing tabbed browser (`tabs`/`activeIndex`); the
    /// RIGHT pane is a single secondary folder created on first split.
    @Published var isSplit: Bool = false
    @Published var rightTab: TabViewModel? = nil
    /// Which pane has keyboard/command focus. Menu commands, the
    /// sidebar, and `activeTab` all target this side.
    @Published var activeSide: PaneSide = .left

    // MARK: Command routing (multi-window scoping)

    /// The AppKit window hosting this window's `ContentView`, captured by
    /// `WindowAccessor`. Menu commands are delivered over NotificationCenter
    /// — a process-wide broadcast — so without window scoping a shortcut
    /// like ⌘V would fire in EVERY open window at once (pasting into two
    /// folders, or one window's empty selection clobbering the clipboard
    /// the other just populated). `weak` so it never keeps a closed window
    /// alive.
    weak var hostWindow: NSWindow?

    /// True when this window should act on a broadcast menu command — i.e.
    /// it is the frontmost (key or main) window. Defaults to `true` until
    /// the host window is captured, so a lone window works at launch.
    var isCommandTarget: Bool {
        guard let w = hostWindow else { return true }
        if w.isKeyWindow || w.isMainWindow { return true }
        // Defensive fallback: if the whole app currently has NO key/main
        // window (a focus glitch), act anyway so commands never silently
        // die. With two real windows exactly one is key, so this never
        // misfires there.
        return NSApp.keyWindow == nil && NSApp.mainWindow == nil
    }

    /// Cache so each command name hands SwiftUI the SAME publisher
    /// instance across body re-evaluations — a fresh AnyPublisher per
    /// render forced `.onReceive` to tear down and resubscribe 31 times
    /// per re-render. Plain dictionary (not @Published): mutating it
    /// during a body evaluation must not trigger another render.
    private var cmdPublishers: [Notification.Name: AnyPublisher<Notification, Never>] = [:]

    /// A menu-command publisher scoped to THIS window: it forwards the
    /// notification only when this is the frontmost window. Use in place of
    /// `NotificationCenter.default.publisher(for:)` for every command
    /// handler so broadcasts don't run in background windows too.
    func cmd(_ name: Notification.Name) -> AnyPublisher<Notification, Never> {
        if let cached = cmdPublishers[name] { return cached }
        let publisher = NotificationCenter.default.publisher(for: name)
            .filter { [weak self] _ in
                // Posts come from main-thread UI; the closure itself is
                // nonisolated, hence the explicit hop.
                MainActor.assumeIsolated { self?.isCommandTarget ?? false }
            }
            .eraseToAnyPublisher()
        cmdPublishers[name] = publisher
        return publisher
    }

    /// Enter / leave split view. On first enter, the right pane opens at
    /// the left pane's current folder so the user has a familiar start.
    func toggleSplit() {
        if isSplit {
            isSplit = false
            activeSide = .left
        } else {
            if rightTab == nil {
                rightTab = TabViewModel(startAt: leftTab.currentURL)
            }
            isSplit = true
        }
    }

    /// Give a pane focus (click-to-activate). No-op when not split.
    func focus(_ side: PaneSide) {
        guard isSplit else { return }
        if activeSide != side { activeSide = side }
    }

    /// The left pane's currently-visible tab.
    var leftTab: TabViewModel {
        guard activeIndex >= 0 && activeIndex < tabs.count else { return tabs[0] }
        return tabs[activeIndex]
    }

    /// Stack of URLs from recently-closed tabs. ⌘⇧T pops the top one
    /// and opens it in a new tab — Windows Explorer & every browser.
    private var recentlyClosedURLs: [URL] = []

    /// Key for the persisted tab list. Stored as JSON: a struct with
    /// the array of tab paths and the active index, so restoring a
    /// session lands the user back on whichever tab they had open.
    private static let persistedSessionKey = "fe.windowSession"

    private struct PersistedSession: Codable {
        let paths: [String]
        let activeIndex: Int
    }

    init() {
        // Try to bring back the last session's tabs. Each path is
        // validated against the live file system so a folder that was
        // moved/deleted while the app was quit just falls out of the
        // list instead of crashing the restore.
        let restored = Self.loadPersistedSession()
        if restored.isEmpty {
            self.tabs = [TabViewModel()]
        } else {
            self.tabs = restored.map { TabViewModel(startAt: $0) }
        }
        if let savedIndex = Self.loadPersistedActiveIndex(),
           savedIndex >= 0, savedIndex < tabs.count {
            self.activeIndex = savedIndex
        }
    }

    /// Used when a tab is torn off into a brand-new window (TabBar's
    /// "Move to New Window", via `openWindow(value: url)`). Starts with
    /// exactly that one tab — deliberately does NOT restore the
    /// persisted session, which is only appropriate for the app's
    /// original launch window.
    init(singleTabAt url: URL) {
        self.tabs = [TabViewModel(startAt: url)]
    }

    // MARK: - Persistence

    /// Snapshot the current tab list (paths + active index) to
    /// UserDefaults. Called when tabs change and again on app quit so
    /// the next launch comes up exactly where the user left off.
    func persistSession() {
        let session = PersistedSession(
            paths: tabs.map { $0.currentURL.path },
            activeIndex: activeIndex
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.persistedSessionKey)
        }
    }

    private static func loadPersistedSession() -> [URL] {
        guard let data = UserDefaults.standard.data(forKey: persistedSessionKey),
              let decoded = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else { return [] }
        return decoded.paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileSystemService.isReadableDirectory($0) }
    }

    private static func loadPersistedActiveIndex() -> Int? {
        guard let data = UserDefaults.standard.data(forKey: persistedSessionKey),
              let decoded = try? JSONDecoder().decode(PersistedSession.self, from: data)
        else { return nil }
        return decoded.activeIndex
    }

    // MARK: - Convenience

    /// The tab that menu commands / sidebar / keyboard act on — the
    /// focused pane's tab. Falls back to the left pane when not split.
    var activeTab: TabViewModel {
        if isSplit, activeSide == .right, let r = rightTab { return r }
        return leftTab
    }

    // MARK: - Tab lifecycle

    func newTab(at url: URL? = nil) {
        let start = url ?? FileManager.default.homeDirectoryForCurrentUser
        tabs.append(TabViewModel(startAt: start))
        activeIndex = tabs.count - 1
        // The tab strip belongs to the LEFT pane — interacting with it
        // moves command focus there, so ⌘-shortcuts follow the tab the
        // user just opened instead of a still-focused right pane.
        activeSide = .left
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Last tab? Don't actually close the window — Windows Explorer
        // keeps at least one tab open. We still record the current URL
        // so ⌘⇧T can bring it back after the implicit "navigate home".
        if tabs.count == 1 {
            let url = tabs[0].currentURL
            let home = FileManager.default.homeDirectoryForCurrentUser
            if url != home {
                recentlyClosedURLs.append(url)
            }
            tabs[0].navigate(to: home)
            return
        }
        recentlyClosedURLs.append(tabs[index].currentURL)
        tabs.remove(at: index)
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if activeIndex > index {
            activeIndex -= 1
        }
        activeSide = .left
    }

    func closeActiveTab() {
        closeTab(at: activeIndex)
    }

    func reopenLastClosed() {
        guard let url = recentlyClosedURLs.popLast() else { return }
        newTab(at: url)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        activeSide = .left
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source),
              destination >= 0, destination <= tabs.count else { return }
        let was = tabs.remove(at: source)
        let dst = destination > source ? destination - 1 : destination
        tabs.insert(was, at: dst)
        // Keep the same logical tab focused.
        if let newIndex = tabs.firstIndex(where: { $0 === was }) {
            activeIndex = newIndex
        }
    }
}
