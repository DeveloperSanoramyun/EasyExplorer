//
//  ActionToolbar.swift
//  FileExplorer
//
//  Optional action-button row between the tab strip and address bar.
//  Hidden by default — the View menu exposes a toggle since the rest
//  of the app already has every action reachable via menus / shortcuts
//  / context menus. The toolbar exists primarily for discoverability
//  on the common file operations.
//

import SwiftUI

struct ActionToolbar: View {
    @ObservedObject var tab: TabViewModel
    @ObservedObject var clipboard: ClipboardService

    var body: some View {
        HStack(spacing: 4) {
            button("plus.rectangle.on.folder",
                   help: "New Folder (⌘⇧N)",
                   enabled: true) {
                tab.createNewFolder()
            }

            Divider().frame(height: 14)

            button("scissors",
                   help: "Cut (⌘X)",
                   enabled: !tab.selectedURLs.isEmpty) {
                clipboard.cut(tab.selectedURLs)
            }
            button("doc.on.doc",
                   help: "Copy (⌘C)",
                   enabled: !tab.selectedURLs.isEmpty) {
                clipboard.copy(tab.selectedURLs)
            }
            button("doc.on.clipboard",
                   help: "Paste (⌘V)",
                   enabled: clipboard.hasContent) {
                tab.paste()
            }

            Divider().frame(height: 14)

            button("trash",
                   help: "Move to Trash (⌘⌫)",
                   enabled: !tab.selectedURLs.isEmpty) {
                tab.moveSelectedToTrash()
            }
            button("plus.square.on.square",
                   help: "Duplicate (⌘D)",
                   enabled: !tab.selectedURLs.isEmpty) {
                tab.duplicateSelected()
            }

            Divider().frame(height: 14)

            button("info.circle",
                   help: "Get Info (⌘I)",
                   enabled: true) {
                NotificationCenter.default.post(name: .feShowProperties, object: nil)
            }
            button("square.and.arrow.up",
                   help: "Share…",
                   enabled: !tab.selectedURLs.isEmpty) {
                ShareService.showPicker(for: tab.selectedURLs)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    @ViewBuilder
    private func button(
        _ symbol: String,
        help: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .feFont(size: 13)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
