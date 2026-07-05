//
//  FolderSizeService.swift
//  FileExplorer
//
//  Recursive folder size calculation. Off by default because walking a
//  large tree is expensive — the user triggers it explicitly via
//  "Calculate Size" in the context menu. Results are cached in memory
//  and invalidated when the folder is modified (FSEvents).
//

import Foundation
import Combine

@MainActor
final class FolderSizeService: ObservableObject {

    static let shared = FolderSizeService()

    /// Cached byte-counts keyed by folder URL. nil = not yet calculated.
    @Published private(set) var sizes: [URL: Int64] = [:]

    private init() {}

    func cachedSize(of url: URL) -> Int64? { sizes[url] }

    func invalidate(_ url: URL) {
        sizes.removeValue(forKey: url)
    }

    func invalidateAll() {
        sizes.removeAll()
    }

    /// Drop cached sizes for CHILDREN of `parent` that no longer appear
    /// in `currentURLs` — i.e. folders renamed or trashed externally.
    /// Called from TabViewModel.reload().
    ///
    /// Scoped to `parent`'s direct children on purpose: the previous
    /// version removed EVERY key not in the current listing, so merely
    /// navigating from folder A to folder B wiped all of A's calculated
    /// sizes — "Calculate Size" results never survived a revisit.
    func invalidateMissing(from currentURLs: Set<URL>, in parent: URL) {
        let stale = sizes.keys.filter {
            $0.deletingLastPathComponent() == parent && !currentURLs.contains($0)
        }
        for url in stale {
            sizes.removeValue(forKey: url)
        }
    }

    // MARK: - Async calculation

    /// Walk the folder tree off the main thread, summing every regular
    /// file's `totalFileAllocatedSize`. Updates `sizes[url]` on completion.
    func calculate(_ url: URL) async {
        let total = await Task.detached(priority: .utility) {
            Self.directorySize(at: url)
        }.value
        sizes[url] = total
    }

    nonisolated private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        var sum: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            // Prefer allocated size (matches Finder's "Get Info"); fall
            // back to logical fileSize.
            let bytes = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
            sum += Int64(bytes)
        }
        return sum
    }
}
