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
import AppKit
import Darwin

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
        var failures: [String] = []
        for url in urls {
            guard let original = rememberedOriginal(url) else {
                failures.append("\(url.lastPathComponent): original location is unavailable. Use Put Back in Finder.")
                continue
            }
            do {
                guard !SafeFiles.exists(original) else { throw SafeFiles.error("Original location is occupied: \(original.path)") }
                try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: original)
            } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            let alert = NSAlert(); alert.messageText = "Some items could not be restored"
            alert.informativeText = failures.prefix(10).joined(separator: "\n"); alert.runModal()
        }
    }

    static func remember(original: URL, trash: URL) {
        guard let identity = try? FileIdentity(trash) else { return }
        var records = UserDefaults.standard.dictionary(forKey: "fe.trashOrigins") as? [String: [String: String]] ?? [:]
        records[trash.path] = ["original": original.path, "device": String(identity.device), "inode": String(identity.inode)]
        // Bound metadata; the actual files are managed by the system Trash.
        if records.count > 10_000 { records = records.filter { SafeFiles.exists(URL(fileURLWithPath: $0.key)) } }
        UserDefaults.standard.set(records, forKey: "fe.trashOrigins")
    }
    private static func rememberedOriginal(_ trash: URL) -> URL? {
        let records = UserDefaults.standard.dictionary(forKey: "fe.trashOrigins") as? [String: [String: String]] ?? [:]
        guard let record = records[trash.path], let identity = try? FileIdentity(trash),
              record["device"] == String(identity.device), record["inode"] == String(identity.inode),
              let original = record["original"] else { return nil }
        return URL(fileURLWithPath: original)
    }

    /// Ask Finder where a trashed item used to live. Public API doesn't
    /// expose this — we go via Finder scripting, which means the call
    /// triggers Automation consent on first use. Returns nil when the
    /// item isn't in the trash, Finder denies access, or the original
    /// folder no longer exists.
    static func originalLocation(of url: URL) -> URL? {
        guard TrashHelper.isInTrash(url) else { return nil }
        if let original = rememberedOriginal(url) { return original.deletingLastPathComponent() }
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
            let alert = NSAlert(); alert.messageText = "Trash operation failed"
            alert.informativeText = "\(error)"; alert.runModal()
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
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var roots = [trashURL]
        roots += (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? [])
            .map { $0.appendingPathComponent(".Trashes/" + String(getuid())) }
        return roots.contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }
}
