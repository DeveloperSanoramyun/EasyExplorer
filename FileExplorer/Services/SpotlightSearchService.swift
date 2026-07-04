//
//  SpotlightSearchService.swift
//  FileExplorer
//
//  Thin wrapper around `NSMetadataQuery` for system-wide file search.
//  Results stream in via the gathering/update notifications and are
//  delivered to subscribers on the main queue.
//
//  Usage:
//      let service = SpotlightSearchService()
//      service.search("invoice", scope: nil)         // search everything
//      service.search("README", scope: someFolderURL) // confine to subtree
//      // Observe `results` via @ObservedObject.
//

import Foundation
import Combine

@MainActor
final class SpotlightSearchService: ObservableObject {

    /// File URLs returned by the active query. Capped at `resultLimit`
    /// so UIs aren't asked to render 50 000 rows.
    @Published private(set) var results: [URL] = []
    @Published private(set) var isSearching: Bool = false

    private let resultLimit = 500
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    deinit {
        // Tear down on dealloc (deinit is nonisolated; observer removal
        // is thread-safe on NotificationCenter).
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        query?.stop()
    }

    // MARK: - Public API

    /// Start a fresh filename query. Replaces any existing search.
    func search(_ text: String, scope: URL? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { stop(); return }
        let predicate = NSPredicate(
            format: "%K LIKE[cd] %@",
            NSMetadataItemFSNameKey, "*\(trimmed)*"
        )
        start(predicate: predicate, scope: scope)
    }

    /// Find every file tagged with `tagName`. Used by the sidebar's
    /// Tags section — `kMDItemUserTags` is the multi-value attribute
    /// Finder writes when the user applies a colour tag.
    func searchByTag(_ tagName: String, scope: URL? = nil) {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { stop(); return }
        // LIKE on a multi-value attribute matches the array element-wise.
        let predicate = NSPredicate(
            format: "%K LIKE[cd] %@",
            "kMDItemUserTags", trimmed
        )
        start(predicate: predicate, scope: scope)
    }

    private func start(predicate: NSPredicate, scope: URL?) {
        stop()
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = scope.map { [$0 as Any] }
            ?? [NSMetadataQueryLocalComputerScope]
        // Batching reduces UI churn while results flood in.
        q.notificationBatchingInterval = 0.3

        // Read the query back off `self.query` (set just below) inside the
        // @MainActor hop rather than capturing the local `q` directly —
        // `NSMetadataQuery` isn't Sendable, so closing over it across the
        // @Sendable NotificationCenter callback boundary is unsound even
        // though delivery is already serialized on `queue: .main`.
        let gather = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let query = self.query else { return }
                self.handleResults(query)
                self.isSearching = false
            }
        }
        let update = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: q, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let query = self.query else { return }
                self.handleResults(query)
            }
        }
        observers = [gather, update]

        isSearching = true
        results = []
        query = q
        q.start()
    }

    func stop() {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        query = nil
        results = []
        isSearching = false
    }

    // MARK: - Results

    private func handleResults(_ q: NSMetadataQuery) {
        q.disableUpdates()
        defer { q.enableUpdates() }

        var urls: [URL] = []
        urls.reserveCapacity(min(q.resultCount, resultLimit))
        for i in 0..<min(q.resultCount, resultLimit) {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            urls.append(URL(fileURLWithPath: path))
        }
        results = urls
    }
}
