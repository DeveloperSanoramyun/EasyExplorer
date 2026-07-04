//
//  QuickLookCoordinator.swift
//  FileExplorer
//
//  Bridges our selection state to QLPreviewPanel — macOS's built-in
//  Space-bar preview floating window. The panel is a global singleton
//  with a strict delegate API, so we wrap it behind one shared
//  coordinator that any view can hand the latest selection to and
//  call `show()`.
//

import Foundation
import AppKit
import Quartz

@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    static let shared = QuickLookCoordinator()

    private var items: [URL] = []
    private var currentIndex: Int = 0

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Hand the panel a list of URLs to cycle through. The first item is
    /// shown when the panel opens; the user can arrow-key through the
    /// rest. Pass the multi-selection in display order so left/right
    /// arrows feel right.
    func show(_ urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        items = urls
        currentIndex = max(0, min(index, urls.count - 1))

        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            // Already open — just refresh contents for the new selection.
            panel.reloadData()
            panel.currentPreviewItemIndex = currentIndex
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.currentPreviewItemIndex = currentIndex
        }
    }

    /// Close the panel if it's currently open.
    func close() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// True when the panel is currently displayed. Useful for toggling
    /// behaviour on subsequent Space presses (open ↔ close).
    var isOpen: Bool {
        QLPreviewPanel.shared()?.isVisible ?? false
    }

    // MARK: - QLPreviewPanelDataSource

    // The protocol requirements are nonisolated; QLPreviewPanel calls
    // them from its own queue. We only read `items`, which is mutated
    // exclusively on the main actor in `show(_:startingAt:)`, so the
    // read is safe — but we mark the methods nonisolated so Swift 6
    // doesn't object to the cross-actor satisfaction.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            items.indices.contains(index) ? items[index] as NSURL : nil
        }
    }
}
