import Foundation
import Combine

@MainActor
final class FolderSizeService: ObservableObject {
    static let shared = FolderSizeService()
    struct Measurement {
        let logical: Int64
        let allocated: Int64
        let unreadable: Int
        var summary: String {
            let a = ByteCountFormatter.string(fromByteCount: logical, countStyle: .file)
            let b = ByteCountFormatter.string(fromByteCount: allocated, countStyle: .file)
            return "\(a) (\(b) on disk)" + (unreadable > 0 ? " — incomplete: \(unreadable) unreadable item(s)" : "")
        }
    }
    @Published private(set) var sizes: [URL: Int64] = [:]
    @Published private(set) var measurements: [URL: Measurement] = [:]
    private var generations: [URL: UUID] = [:]
    private init() {}
    func cachedSize(of url: URL) -> Int64? { sizes[url] }
    func summary(of url: URL) -> String? { measurements[url]?.summary }
    func invalidate(_ url: URL) { sizes[url] = nil; measurements[url] = nil; generations[url] = UUID() }
    func invalidateAll() { for url in Set(sizes.keys).union(generations.keys) { invalidate(url) } }
    func invalidateTree(_ changed: URL) {
        for url in Set(sizes.keys).union(generations.keys) where SafeFiles.isInside(changed, url) || SafeFiles.isInside(url, changed) { invalidate(url) }
    }
    func invalidateMissing(from currentURLs: Set<URL>, in parent: URL) {
        for url in Array(sizes.keys) where url.deletingLastPathComponent() == parent && !currentURLs.contains(url) { invalidate(url) }
    }
    func calculate(_ url: URL) async {
        let generation = UUID(); generations[url] = generation
        let total = await Task.detached(priority: .utility) { Self.measure(url) }.value
        guard generations[url] == generation else { return }
        measurements[url] = total; sizes[url] = total.logical
    }
    nonisolated static func measure(_ url: URL) -> Measurement {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        var unreadable = 0
        var logical: Int64 = 0, allocated: Int64 = 0
        var seen: Set<String> = []
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in unreadable += 1; return true }) else { return Measurement(logical: 0, allocated: 0, unreadable: 1) }
        for case let file as URL in iterator {
            do {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let identity = try FileIdentity(file)
                guard seen.insert("\(identity.device):\(identity.inode)").inserted else { continue }
                logical += Int64(values.fileSize ?? 0)
                allocated += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            } catch { unreadable += 1 }
        }
        return Measurement(logical: logical, allocated: allocated, unreadable: unreadable)
    }
}
