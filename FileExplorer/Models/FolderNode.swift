//
//  FolderNode.swift
//  FileExplorer
//
//  Lazy-loaded tree node for the sidebar's expandable folder hierarchy.
//  Children are populated only when the user clicks the disclosure
//  arrow — large directories are never enumerated until needed.
//

import Foundation
import Combine

@MainActor
final class FolderNode: ObservableObject, Identifiable, Hashable {

    nonisolated static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.url == rhs.url
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    nonisolated var id: URL { url }
    let url: URL
    let displayName: String
    let symbol: String

    @Published var children: [FolderNode]? = nil   // nil = not yet loaded
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false

    init(url: URL, displayName: String? = nil, symbol: String = "folder") {
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.symbol = symbol
    }

    /// Load this node's direct subdirectories off the main actor. Files
    /// are excluded — the sidebar tree only shows folders, matching
    /// Windows Explorer's Navigation Pane behaviour. Large directories
    /// (e.g. `/System/Library/Frameworks`) used to freeze the sidebar
    /// for several seconds when the user clicked the chevron; the load
    /// is now a detached Task and the row shows a spinner while it runs.
    func loadChildrenIfNeeded() {
        guard children == nil, !isLoading else { return }
        isLoading = true
        let targetURL = url
        Task {
            let listed = await Self.listSubdirectoriesOffMain(targetURL)
            await MainActor.run {
                self.children = listed.map { FolderNode(url: $0.url, displayName: $0.name) }
                self.isLoading = false
            }
        }
    }

    /// Off-actor file-system scan. Returns lightweight (URL, displayName)
    /// pairs so we don't hand the @MainActor-bound `FolderNode` type out
    /// of the actor; the wrapper instances are created back on main.
    private nonisolated static func listSubdirectoriesOffMain(
        _ url: URL
    ) async -> [(url: URL, name: String)] {
        await Task.detached(priority: .userInitiated) {
            guard let entries = try? FileSystemService.listDirectory(at: url, includeHidden: false) else {
                return []
            }
            return entries
                .filter { $0.isDirectory && !$0.isPackage }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { (url: $0.url, name: $0.name) }
        }.value
    }

    func toggleExpanded() {
        if !isExpanded {
            if children == nil {
                loadChildrenIfNeeded()
            } else {
                // Re-expanding: refresh in the background so folders
                // created/deleted since the last load show up — the old
                // `children == nil` guard meant the tree NEVER updated
                // after the first expansion short of an app restart.
                // The stale list stays visible while the fresh one
                // loads (no spinner flash); existing FolderNode
                // instances are reused by URL so grandchild expansion
                // state survives the refresh.
                refreshChildren()
            }
        }
        isExpanded.toggle()
    }

    private func refreshChildren() {
        guard !isLoading else { return }
        let targetURL = url
        Task {
            let listed = await Self.listSubdirectoriesOffMain(targetURL)
            await MainActor.run {
                let existing = Dictionary(uniqueKeysWithValues:
                    (self.children ?? []).map { ($0.url, $0) })
                self.children = listed.map {
                    existing[$0.url] ?? FolderNode(url: $0.url, displayName: $0.name)
                }
            }
        }
    }
}
