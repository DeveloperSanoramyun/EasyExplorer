//
//  BookmarkService.swift
//  FileExplorer
//
//  Stores the user's pinned folders ("Quick Access") and the most
//  recently visited locations. Both lists are persisted to UserDefaults
//  as path strings; the sidebar reads them on each render.
//
//  Why paths and not security-scoped bookmarks? We run with sandbox
//  OFF (Finder-replacement use case), so plain absolute paths work and
//  survive across app launches without needing to re-grant access.
//

import Foundation
import Combine

@MainActor
final class BookmarkService: ObservableObject {

    static let shared = BookmarkService()

    @Published private(set) var pinned: [URL] = []
    @Published private(set) var recents: [URL] = []

    private let pinnedKey = "fe.pinnedFolders"
    private let recentsKey = "fe.recentFolders"
    private let recentsLimit = 50

    private init() {
        load()
    }

    // MARK: - Pinning

    func pin(_ url: URL) {
        guard !pinned.contains(url) else { return }
        pinned.append(url)
        save()
    }

    func unpin(_ url: URL) {
        pinned.removeAll { $0 == url }
        save()
    }

    func isPinned(_ url: URL) -> Bool {
        pinned.contains(url)
    }

    func reorder(from source: Int, to destination: Int) {
        guard pinned.indices.contains(source),
              destination >= 0, destination <= pinned.count else { return }
        let item = pinned.remove(at: source)
        let dst = destination > source ? destination - 1 : destination
        pinned.insert(item, at: dst)
        save()
    }

    // MARK: - Recents

    /// Push a URL onto the recent-folders stack. Skips ephemeral system
    /// directories (`/private/var/...`, `/tmp/...`) so the list stays
    /// useful — the user rarely revisits those.
    func recordVisit(_ url: URL) {
        let path = url.path
        let blacklist = ["/private/var", "/tmp", "/private/tmp", "/var/folders"]
        if blacklist.contains(where: { path.hasPrefix($0) }) { return }
        if url == FileManager.default.homeDirectoryForCurrentUser { return }

        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > recentsLimit {
            recents = Array(recents.prefix(recentsLimit))
        }
        save()
    }

    func clearRecents() {
        recents.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let pinnedPaths = defaults.array(forKey: pinnedKey) as? [String] {
            pinned = pinnedPaths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let recentPaths = defaults.array(forKey: recentsKey) as? [String] {
            recents = recentPaths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(pinned.map(\.path), forKey: pinnedKey)
        defaults.set(recents.map(\.path), forKey: recentsKey)
    }
}
