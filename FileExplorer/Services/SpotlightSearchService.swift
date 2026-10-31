import Foundation
import Combine

@MainActor
final class SpotlightSearchService: ObservableObject {
    @Published private(set) var results: [URL] = []
    @Published private(set) var isSearching = false
    @Published private(set) var hasMore = false
    @Published private(set) var notice: String?
    private var limit = 500
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var scanControl = OperationControl()
    private var scanned: [URL] = []
    private var scanning = false
    private var gathering = false
    deinit { scanControl.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) }; query?.stop() }

    func search(_ text: String, scope: URL? = nil, contents: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { stop(); return }
        let predicate = contents
            ? NSPredicate(format: "%K CONTAINS[cd] %@ OR %K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text, "kMDItemTextContent", text)
            : NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
        start(predicate, scope: scope)
        if let scope { startScan(text, scope: scope, contents: contents) }
    }
    func searchByTag(_ tag: String, scope: URL? = nil) {
        guard !tag.isEmpty else { stop(); return }
        start(NSPredicate(format: "%K LIKE[cd] %@", "kMDItemUserTags", tag), scope: scope)
    }
    func loadMore() { limit += 500; publish() }
    func stop() {
        generation = UUID(); scanControl.cancel(); scanControl = OperationControl()
        query?.stop(); query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        results = []; scanned = []; hasMore = false; notice = nil
        gathering = false; scanning = false; isSearching = false; limit = 500
    }
    private func start(_ predicate: NSPredicate, scope: URL?) {
        stop()
        let q = NSMetadataQuery(); query = q
        q.predicate = predicate
        q.searchScopes = scope.map { [$0 as Any] } ?? [NSMetadataQueryLocalComputerScope]
        q.notificationBatchingInterval = 0.3
        let id = generation
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] notification in
                let finished = notification.name == .NSMetadataQueryDidFinishGathering
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    if finished { self.gathering = false }
                    self.publish()
                }
            })
        }
        gathering = true; isSearching = true
        if !q.start() { gathering = false; isSearching = false; notice = "Spotlight is unavailable; folder search can still scan the disk." }
    }
    private func publish() {
        var all = scanned
        var seen = Set(all)
        if let q = query {
            q.disableUpdates(); defer { q.enableUpdates() }
            for i in 0..<min(q.resultCount, limit + 1) {
                guard let item = q.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let url = URL(fileURLWithPath: path)
                if seen.insert(url).inserted { all.append(url) }
            }
            hasMore = q.resultCount > limit || all.count > limit
        } else { hasMore = all.count > limit }
        results = Array(all.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(limit))
        isSearching = gathering || scanning
    }
    private func startScan(_ text: String, scope: URL, contents: Bool) {
        let id = generation, control = scanControl
        scanning = true; isSearching = true
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { Self.scan(text, scope: scope, contents: contents, control: control) }.value
            guard let self, self.generation == id else { return }
            self.scanned = scan.urls; self.scanning = false; self.notice = scan.notice; self.publish()
        }
    }
    struct ScanResult { let urls: [URL]; let notice: String? }
    nonisolated static func scan(_ text: String, scope: URL, contents: Bool, control: OperationControl) -> ScanResult {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var unreadable = 0
        let deadline = Date().addingTimeInterval(60)
        guard let iterator = FileManager.default.enumerator(at: scope, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { _, _ in unreadable += 1; return true }) else { return ScanResult(urls: [], notice: "Folder could not be scanned.") }
        var urls: [URL] = []
        var limited = false
        let textExtensions: Set<String> = ["txt", "md", "csv", "tsv", "json", "xml", "html", "css", "js", "ts", "swift", "py", "c", "h", "log", "yaml", "yml", "tex"]
        for case let url as URL in iterator {
            if control.isCancelled { break }
            if Date() > deadline || urls.count >= 50_000 { limited = true; break }
            if url.lastPathComponent.contains(".FileExplorer-Recovery-") { iterator.skipDescendants(); continue }
            var matches = url.lastPathComponent.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if !matches, contents, textExtensions.contains(url.pathExtension.lowercased()),
               let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
               v.isSymbolicLink != true, (v.fileSize ?? Int.max) <= 1_048_576,
               v.isUbiquitousItem != true || v.ubiquitousItemDownloadingStatus == .current,
               let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               let string = String(data: data, encoding: .utf8) {
                matches = string.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            if matches { urls.append(url) }
        }
        var notes: [String] = []
        if limited { notes.append("Scan stopped at 60 seconds or 50,000 matches. Narrow the folder or query.") }
        if unreadable > 0 { notes.append("\(unreadable) folder(s) could not be read.") }
        if contents { notes.append("Disk content scan covers local UTF-8 text files up to 1 MB; Spotlight may include other indexed formats.") }
        return ScanResult(urls: urls, notice: notes.isEmpty ? nil : notes.joined(separator: " "))
    }
}
