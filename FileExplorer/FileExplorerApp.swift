//
//  FileExplorerApp.swift
//  FileExplorer
//

import SwiftUI

@main
struct FileExplorerApp: App {
    // @AppStorage on the App struct lets SwiftUI's CommandGroup `Toggle`
    // automatically render a ✓ checkmark when the value is true.
    @AppStorage("fe.showHidden")      private var showHidden:      Bool = false
    @AppStorage("fe.showPreview")     private var showPreview:     Bool = false
    @AppStorage("fe.showExtensions")  private var showExtensions:  Bool = true
    @AppStorage("fe.showToolbar")     private var showToolbar:     Bool = false
    /// Used by the ⌘1‥⌘9 menu items to grey themselves out when no
    /// such tab exists. SwiftUI Commands can't observe a window-scoped
    /// state directly, so this is the cheap "always-show-9-shortcuts"
    /// trade-off: a global tab count broadcast onto NotificationCenter
    /// is impractical, but the explicit @AppStorage hack is okay since
    /// only this app reads/writes the key.
    @AppStorage("fe.activeTabCount") private var activeTabCount: Int = 1
    // No @AppStorage("fe.viewMode") here — view-mode changes route
    // through `feSetViewMode` so they can land on the active tab's
    // folder. The global default for unseen folders still lives in
    // @AppStorage but is read from ContentView / FileListView instead.

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // ── File menu (additions)
            CommandGroup(after: .newItem) {
                Button("New Tab") { post(.feNewTab) }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { post(.feCloseTab) }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reopen Closed Tab") { post(.feReopenClosedTab) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("New Folder") { post(.feNewFolder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            // ⌘1‥⌘9 select the Nth tab (Safari / Chrome convention).
            // Greys out shortcuts beyond the current tab count so ⌘5 on
            // a two-tab window doesn't look like a broken menu item.
            CommandGroup(after: .windowList) {
                ForEach(1...9, id: \.self) { n in
                    Button("Show Tab \(n)") {
                        NotificationCenter.default.post(
                            name: .feSelectTab, object: nil,
                            userInfo: ["index": n - 1]
                        )
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(n > activeTabCount)
                }
            }

            // ── Undo / Redo — replace the default text-undo group with
            // file-operation undo. Posts notifications so ContentView
            // can route to the active tab's per-tab undo stack.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { post(.feUndo) }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { post(.feRedo) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            // ── Edit menu — replace Cut/Copy/Paste/Delete with file ops.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut")  { post(.feCutSelection) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("Copy") { post(.feCopySelection) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { post(.fePaste) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Select All") { post(.feSelectAll) }
                    .keyboardShortcut("a", modifiers: .command)
                Divider()
                // ⌥⌘C = Finder's "Copy as Pathname". Falls back to the
                // current folder when nothing is selected so it doubles
                // as "copy this folder's path".
                Button("Copy Path") { post(.feCopyPath) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Duplicate") { post(.feDuplicateSelection) }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Rename") { post(.feRenameSelection) }
                    .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button("Move to Trash") { post(.feMoveSelectionToTrash) }
                    .keyboardShortcut(.delete, modifiers: .command)
                Button("Delete Permanently…") { post(.feDeleteSelectionPermanently) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }

            // ── Find — ⌘F focuses the folder search box; ⌘⇧F switches
            // the scope to "This Mac" Spotlight.
            CommandGroup(after: .textEditing) {
                Button("Find") { post(.feFocusSearchFolder) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find on This Mac…") { post(.feFocusSearchGlobal) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // ── Get Info / Properties (⌘I — Mac convention)
            CommandGroup(after: .pasteboard) {
                Button("Get Info") { post(.feShowProperties) }
                    .keyboardShortcut("i", modifiers: .command)
            }

            // ── Go menu
            CommandMenu("Go") {
                Button("Back") { post(.feGoBack) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { post(.feGoForward) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Up") { post(.feGoUp) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Refresh") { post(.feReload) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Go to Path…") { post(.feFocusAddressBar) }
                    .keyboardShortcut("l", modifiers: .command)
            }

            // ── View menu — Toggle widgets render a ✓ checkmark when on.
            CommandGroup(after: .sidebar) {
                Button("Hide / Show Sidebar") { post(.feToggleSidebar) }
                    .keyboardShortcut("\\", modifiers: .command)
                Divider()
                Toggle("Show Toolbar", isOn: $showToolbar)
                Toggle("Show Preview Pane", isOn: $showPreview)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Split View") { post(.feToggleSplit) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Toggle("Show Hidden Files", isOn: $showHidden)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Toggle("Show File Extensions", isOn: $showExtensions)
                Divider()
                // View modes — three explicit buttons, ⌘⇧ 1 / 2 / 3
                // (Windows muscle memory). The Picker version that
                // used to live here wrote straight to @AppStorage and
                // therefore couldn't target the active tab's folder for
                // per-folder persistence — these post a notification so
                // ContentView can route the change to FolderViewModeService.
                Button("Extra Large Icons") { postViewMode(.extraLargeIcons) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Icons View")        { postViewMode(.icons) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("List View")         { postViewMode(.list) }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Button("Details View")      { postViewMode(.details) }
                    .keyboardShortcut("4", modifiers: [.command, .shift])
                Divider()
                Menu("Group by") {
                    ForEach(GroupKey.allCases) { key in
                        Button(key.displayName) {
                            NotificationCenter.default.post(
                                name: .feSetGroupBy, object: nil,
                                userInfo: ["key": key.rawValue]
                            )
                        }
                    }
                }
                Divider()
                // Global text-zoom — matches Safari / Mail / most macOS
                // apps. The "=" key carries the + symbol on US layouts,
                // so we register both forms to be safe across locales.
                Button("Increase Text Size") { post(.feFontSizeIncrease) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Text Size") { post(.feFontSizeDecrease) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Text Size")   { post(.feFontSizeReset) }
                    .keyboardShortcut("0", modifiers: .command)
            }

            // ── Help menu — Folder Access guide. Re-opens the
            // first-run onboarding sheet so the user can grant Full
            // Disk Access without hunting through System Settings.
            CommandGroup(replacing: .help) {
                Button("Folder Access…") { post(.feShowPermissionGuide) }
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func postViewMode(_ mode: FileViewMode) {
        NotificationCenter.default.post(
            name: .feSetViewMode, object: nil,
            userInfo: ["mode": mode.rawValue]
        )
    }
}
