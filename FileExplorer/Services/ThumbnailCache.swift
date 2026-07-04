//
//  ThumbnailCache.swift
//  FileExplorer
//
//  Async per-URL thumbnail store backed by QuickLookThumbnailing.
//
//  Design notes:
//   • NOT an ObservableObject. An earlier version published the whole
//     cache dictionary, so every generated thumbnail re-rendered every
//     visible row. Now each `ThumbnailIcon` pulls its own image via
//     `.task` into local @State — only the row whose thumbnail just
//     arrived redraws.
//   • Concurrent requests for the same (URL, size, mtime) key are
//     coalesced: the first starts a QL request, the rest await the same
//     result via continuations.
//   • Failures are remembered so we don't retry forever for files with
//     no thumbnail representation (most .txt / binaries → system icon).
//   • mtime in the key means a file edited on disk gets a fresh request
//     next time it's shown; the stale entry lingers only until FIFO
//     eviction overwrites it.
//

import SwiftUI
import QuickLookThumbnailing
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()

    /// Pixel-size buckets. We round each view's needed icon size onto
    /// the nearest bucket so we don't end up with many near-identical
    /// cache entries for the same image.
    enum SizeClass: Int, Hashable {
        case small  = 32    // Compact / Grouped / Details (16pt @ 2x)
        case medium = 128   // Icons mode (56pt @ 2x)
        case large  = 256   // Extra Large Icons (96pt @ ~2.7x)

        var pixels: CGFloat { CGFloat(rawValue) }
    }

    private struct Key: Hashable {
        let url: URL
        let sizeClass: SizeClass
        let mtime: Date?
    }

    private var cache: [Key: NSImage] = [:]
    private var failures: Set<Key> = []
    /// Continuations waiting on an in-flight QL request, keyed by the
    /// request. The first caller for a key starts generation; the rest
    /// pile their continuations here and all resume together.
    private var waiters: [Key: [CheckedContinuation<NSImage?, Never>]] = [:]
    /// FIFO eviction queue — newest at the end.
    private var insertOrder: [Key] = []

    private let maxCacheEntries = 800
    private let maxFailureEntries = 4000

    private init() {}

    /// Synchronous cache peek — returns an already-generated thumbnail
    /// or nil. Used by views in `body` so a cache hit shows instantly
    /// (no async hop / icon flash).
    func cached(for url: URL, mtime: Date?, sizeClass: SizeClass) -> NSImage? {
        cache[Key(url: url, sizeClass: sizeClass, mtime: mtime)]
    }

    /// Async fetch — returns the cached image, a freshly-generated one,
    /// or nil when QL has no thumbnail representation. Safe to call from
    /// many rows for the same file; the QL request is shared.
    func thumbnail(for url: URL, mtime: Date?, sizeClass: SizeClass) async -> NSImage? {
        let key = Key(url: url, sizeClass: sizeClass, mtime: mtime)
        if let hit = cache[key] { return hit }
        if failures.contains(key) { return nil }
        return await withCheckedContinuation { continuation in
            if waiters[key] != nil {
                waiters[key]?.append(continuation)
            } else {
                waiters[key] = [continuation]
                generate(key)
            }
        }
    }

    private func generate(_ key: Key) {
        let request = QLThumbnailGenerator.Request(
            fileAt: key.url,
            size: CGSize(width: key.sizeClass.pixels,
                         height: key.sizeClass.pixels),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            // `.thumbnail` only — `.icon` would return the generic
            // file-type icon for files with no preview, which is
            // exactly what we're replacing.
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumb, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var image: NSImage?
                if let cg = thumb?.cgImage {
                    image = NSImage(cgImage: cg,
                                    size: CGSize(width: key.sizeClass.pixels,
                                                 height: key.sizeClass.pixels))
                }
                if let image {
                    self.insertCached(key, image: image)
                } else {
                    self.insertFailure(key)
                }
                // Resume every coalesced waiter with the same result.
                let pending = self.waiters.removeValue(forKey: key) ?? []
                for w in pending { w.resume(returning: image) }
            }
        }
    }

    private func insertCached(_ key: Key, image: NSImage) {
        let isNew = cache[key] == nil
        cache[key] = image
        guard isNew else { return }
        insertOrder.append(key)
        while insertOrder.count > maxCacheEntries {
            let oldKey = insertOrder.removeFirst()
            cache.removeValue(forKey: oldKey)
        }
    }

    private func insertFailure(_ key: Key) {
        if failures.count >= maxFailureEntries {
            failures.removeAll()
        }
        failures.insert(key)
    }

}

// MARK: - Reusable thumbnail+icon view

/// Drop-in replacement for `Image(nsImage: item.systemIcon)` that
/// shows the QL thumbnail when one is (or becomes) available and falls
/// back to the system icon otherwise. Loads its own thumbnail via
/// `.task` into local @State, so a thumbnail arriving only redraws this
/// row — not the whole list. Folders always render the system icon.
struct ThumbnailIcon: View {
    let item: FileItem
    let sizeClass: ThumbnailCache.SizeClass
    var pointSize: CGFloat

    @State private var loaded: NSImage?

    /// Identity for `.task(id:)` — when a recycled row is reused for a
    /// different file (or the same file changes on disk), the task
    /// re-runs and reloads.
    private struct LoadID: Equatable {
        let path: String
        let mtime: Date?
        let size: ThumbnailCache.SizeClass
    }

    var body: some View {
        let useSystem = item.isDirectory && !item.isPackage
        // Synchronous cache peek avoids an icon flash for already-warm
        // thumbnails (e.g. scrolling back up).
        let immediate = useSystem ? nil
            : ThumbnailCache.shared.cached(for: item.url,
                                           mtime: item.dateModified,
                                           sizeClass: sizeClass)
        let img: NSImage = useSystem
            ? item.systemIcon
            : (immediate ?? loaded ?? item.systemIcon)

        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .frame(width: pointSize, height: pointSize)
            // Video files get a ▶ badge so they're distinguishable from
            // photos at a glance (Windows / Finder gallery do the same).
            // Only on the larger icon-grid sizes — at 16pt the badge
            // would swamp the poster frame.
            .overlay(alignment: .bottomTrailing) {
                if pointSize >= 40, ThumbnailIcon.isVideo(item) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: pointSize * 0.28))
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .padding(pointSize * 0.04)
                }
            }
            .task(id: LoadID(path: item.url.path,
                             mtime: item.dateModified,
                             size: sizeClass)) {
                // Reset so a recycled row doesn't flash the previous
                // file's thumbnail while the new one loads.
                loaded = nil
                guard !useSystem, immediate == nil else { return }
                let result = await ThumbnailCache.shared.thumbnail(
                    for: item.url,
                    mtime: item.dateModified,
                    sizeClass: sizeClass)
                // The task is cancelled when the row is recycled; don't
                // stamp a stale image onto the new item.
                guard !Task.isCancelled else { return }
                loaded = result
            }
    }

    /// Cheap UTI/extension video check for the badge overlay.
    static func isVideo(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        if let id = item.typeIdentifier, let ut = UTType(id) {
            return ut.conforms(to: .movie) || ut.conforms(to: .video)
        }
        let ext = item.url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv",
                "webm", "mpg", "mpeg", "3gp"].contains(ext)
    }
}
