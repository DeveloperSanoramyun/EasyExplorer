//
//  TrashService.swift
//  FileExplorer
//
//  Empty the system Trash + Restore-from-Trash via AppleScript (Finder
//  scripting). Restore relies on Finder because the original-location
//  metadata isn't exposed through any public Foundation API on a
//  per-item basis.
//

import Foundation
import Combine

/// In-memory cache of trashed-item → original-location lookups. The
/// AppleScript bridge is slow and triggers automation consent on first
/// use, so we batch them once on Trash navigation and read from the
/// cache thereafter.
@MainActor
final class TrashLocationCache: ObservableObject {
    static let shared = TrashLocationCache()

    @Published private(set) var locations: [URL: URL] = [:]
    private var pending: Set<URL> = []

    private init() {}

    /// Returns the cached parent URL, or nil if not yet fetched.
    func parent(of url: URL) -> URL? { locations[url] }

    /// Ask Finder for the original location of each URL not already in
    /// the cache. Runs on the MAIN actor — NSAppleScript (OSA/Apple
    /// Events) is not thread-safe and crashes nondeterministically off
    /// the main thread, which is where the previous `Task.detached`
    /// version put it. `Task.yield()` between items keeps the run loop
    /// breathing so a Trash full of files doesn't freeze the UI for the
    /// whole batch; per-item Finder round-trip jank is the price of
    /// correctness here. The lookups are lazy per visible row (and the
    /// column is hidden by default), so batches stay small in practice.
    func prefetch(_ urls: [URL]) {
        let toFetch = urls.filter { locations[$0] == nil && !pending.contains($0) }
        guard !toFetch.isEmpty else { return }
        pending.formUnion(toFetch)
        Task { @MainActor in
            for url in toFetch {
                let parent = TrashService.originalLocation(of: url)
                if let parent { locations[url] = parent }
                pending.remove(url)
                await Task.yield()
            }
        }
    }

    func invalidate() {
        locations.removeAll()
        pending.removeAll()
    }
}

enum TrashService {

    /// Triggers Finder's "Empty Trash" — pops the standard confirmation
    /// (controlled by the user's Finder preferences).
    static func emptyTrash() {
        runAppleScript("""
        tell application "Finder"
            empty the trash
        end tell
        """)
    }

    /// Asks Finder to put the given trashed items back to their original
    /// locations. Passing items not actually in Trash is a no-op.
    static func restore(_ urls: [URL]) {
        // Build an AppleScript that loops over the supplied paths.
        let posixList = urls
            .map { "(POSIX file \"\(escape($0.path))\") as alias" }
            .joined(separator: ", ")
        guard !posixList.isEmpty else { return }
        runAppleScript("""
        tell application "Finder"
            set theItems to {\(posixList)}
            repeat with theItem in theItems
                try
                    move theItem to (original location of theItem)
                end try
            end repeat
        end tell
        """)
    }

    /// Ask Finder where a trashed item used to live. Public API doesn't
    /// expose this — we go via Finder scripting, which means the call
    /// triggers Automation consent on first use. Returns nil when the
    /// item isn't in the trash, Finder denies access, or the original
    /// folder no longer exists.
    static func originalLocation(of url: URL) -> URL? {
        guard TrashHelper.isInTrash(url) else { return nil }
        let script = """
        tell application "Finder"
            try
                set theItem to ((POSIX file "\(escape(url.path))") as alias)
                return POSIX path of ((original location of theItem) as alias)
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let path = result.stringValue, !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Helpers

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error = error {
            NSLog("Trash AppleScript failed: \(error)")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Path helper

enum TrashHelper {
    /// URL of the current user's Trash folder. Cached on first access.
    static let trashURL: URL = {
        let fm = FileManager.default
        if let url = try? fm.url(for: .trashDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            return url.standardizedFileURL
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
            .standardizedFileURL
    }()

    /// True when `url` lives anywhere inside the Trash folder.
    static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(trashURL.path + "/")
            || url.standardizedFileURL.path == trashURL.path
    }
}
