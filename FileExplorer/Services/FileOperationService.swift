//
//  FileOperationService.swift
//  FileExplorer
//
//  Copy / move / rename / trash / permanent-delete / mkdir, plus a
//  Progress + Conflict reporter so the UI can show a progress sheet and
//  intercept name collisions. Operations run on a detached task so the
//  main thread stays responsive during large copies.
//

import Foundation
import AppKit
import SwiftUI   // NSHostingView for the conflict alert's comparison accessory

// MARK: - Conflict resolution

enum ConflictDecision {
    case skip
    case replace
    case keepBoth      // appends " (copy)" / " (copy 2)" / ...
    case cancel        // abort the whole batch
}

/// User-supplied conflict resolver. Called on the **main thread** so the
/// view can show a sheet and return the decision (and whether to apply
/// it to all subsequent conflicts in this batch).
typealias ConflictResolver = (_ source: URL, _ destination: URL) async -> (decision: ConflictDecision, applyToAll: Bool)

/// App-modal conflict prompt, backed by `NSAlert`.
///
/// Why not a SwiftUI sheet: the copy/move progress is ALSO shown as a
/// `.sheet`, and macOS can't present a second sheet over an active one —
/// the conflict sheet silently fails to appear and the resolver's
/// continuation never resumes, hanging the whole operation. The classic
/// repro is ⌘C then ⌘V in the same folder (the pasted name instantly
/// collides with the original). `NSAlert.runModal()` floats above the
/// progress sheet, so it always shows.
@MainActor
enum ConflictPrompt {
    static func resolver() -> ConflictResolver {
        return { source, destination in
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "An item named \u{201C}\(destination.lastPathComponent)\u{201D} already exists in this location."
                alert.informativeText = "Do you want to replace the existing item, keep both, or skip it?"
                alert.addButton(withTitle: "Replace")    // .alertFirstButtonReturn
                alert.addButton(withTitle: "Keep Both")  // .alertSecondButtonReturn
                alert.addButton(withTitle: "Skip")       // .alertThirdButtonReturn
                alert.addButton(withTitle: "Cancel")     // 4th
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Apply to All"

                // Side-by-side comparison (thumbnails + size/date/path)
                // so same-named files are distinguishable — the alert's
                // text alone can't tell two "photo.jpg" apart.
                let comparison = NSHostingView(rootView: ConflictComparisonView(
                    source: source, destination: destination))
                comparison.frame = NSRect(
                    x: 0, y: 0,
                    width: 460,
                    height: max(90, comparison.fittingSize.height))
                alert.accessoryView = comparison

                let response = alert.runModal()
                let applyToAll = (alert.suppressionButton?.state == .on)
                let decision: ConflictDecision
                switch response {
                case .alertFirstButtonReturn:  decision = .replace
                case .alertSecondButtonReturn: decision = .keepBoth
                case .alertThirdButtonReturn:  decision = .skip
                default:                       decision = .cancel
                }
                return (decision: decision, applyToAll: applyToAll)
            }
        }
    }
}

// MARK: - Progress

@MainActor
final class FileOperationProgress: ObservableObject {
    @Published var currentFileName: String = ""
    @Published var processed: Int = 0
    @Published var total: Int = 0
    @Published var isCancelled: Bool = false
    @Published var isDone: Bool = false
    @Published var errorMessage: String? = nil

    /// Set when the transfer actually begins (first processed item),
    /// so the rate / ETA estimates don't include the user's "Apply to
    /// all" thinking time.
    private var startedAt: Date? = nil

    func fraction(at now: Date = Date()) -> Double {
        total > 0 ? Double(processed) / Double(total) : 0
    }
    var fraction: Double { fraction() }

    /// Items per second over the elapsed transfer time. Returns nil
    /// when fewer than 1 second has passed (too noisy to display).
    var itemsPerSecond: Double? {
        guard let start = startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 1.0, processed > 0 else { return nil }
        return Double(processed) / elapsed
    }

    /// Estimated time remaining in seconds. Nil if we can't compute
    /// (no rate yet, or total unknown).
    var etaSeconds: TimeInterval? {
        guard let rate = itemsPerSecond, rate > 0 else { return nil }
        let remaining = max(0, total - processed)
        return Double(remaining) / rate
    }

    /// Bump `processed` and start the clock on the first increment.
    func tick(filename: String) {
        if startedAt == nil && processed == 0 {
            startedAt = Date()
        }
        currentFileName = filename
        processed += 1
    }

    func cancel() { isCancelled = true }
    func reset() {
        currentFileName = ""
        processed = 0
        total = 0
        isCancelled = false
        isDone = false
        errorMessage = nil
        startedAt = nil
    }
}

// MARK: - Service

enum FileOperationService {

    // MARK: Trash (Recycle Bin)

    /// Move items to the system Trash. Returns each (original URL,
    /// resulting Trash URL) pair so callers can register an undo
    /// action that moves the items back to where they came from.
    /// The trashed URL is `nil` when the FS API doesn't surface a
    /// resulting URL (rare; happens on some volumes).
    @discardableResult
    static func moveToTrash(_ urls: [URL]) -> [(original: URL, trashed: URL?)] {
        var trashed: [(URL, URL?)] = []
        for url in urls {
            var result: NSURL? = nil
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                trashed.append((url, result as URL?))
            } catch {
                // Continue on partial failure — Finder behaves the same way.
                NSLog("trash failed for \(url.path): \(error)")
            }
        }
        return trashed
    }

    // MARK: Permanent delete

    /// Permanently delete (no Trash). Caller must confirm with the user.
    /// Returns the list of items we couldn't delete (per-URL error
    /// strings) — matches `moveToTrash`'s "continue on partial failure"
    /// contract so the user sees what's left vs throws on first error.
    @discardableResult
    static func permanentlyDelete(_ urls: [URL]) -> [String] {
        var errors: [String] = []
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return errors
    }

    // MARK: Rename

    /// Rename a single item. Returns the new URL. Throws if the new name
    /// already exists in the same directory or contains a path separator.
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "FileExplorer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Name cannot be empty."
            ])
        }
        guard !trimmed.contains("/") else {
            throw NSError(domain: "FileExplorer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Name cannot contain \u{201C}/\u{201D}."
            ])
        }
        let parent = url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(trimmed)
        guard newURL.path != url.path else { return url }
        if FileManager.default.fileExists(atPath: newURL.path) {
            throw NSError(domain: "FileExplorer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "An item named \u{201C}\(trimmed)\u{201D} already exists."
            ])
        }
        try FileManager.default.moveItem(at: url, to: newURL)
        return newURL
    }

    // MARK: Duplicate

    /// Finder's "Duplicate" (⌘D) — copy each item next to itself with
    /// a " copy" suffix, " copy 2", " copy 3", … on collision. Returns
    /// the URLs created. Throws on the first failure so partial output
    /// is visible to the user (matches Finder's behaviour).
    @discardableResult
    static func duplicate(_ urls: [URL]) throws -> [URL] {
        var created: [URL] = []
        for url in urls {
            let target = uniquify(url, suffix: " copy")
            try FileManager.default.copyItem(at: url, to: target)
            created.append(target)
        }
        return created
    }

    // MARK: New folder

    /// Create a new folder. Picks a non-colliding name "New Folder",
    /// "New Folder 2", etc. when `baseName` is already taken.
    @discardableResult
    static func createNewFolder(in parent: URL, baseName: String = "New Folder") throws -> URL {
        let fm = FileManager.default
        var attempt = parent.appendingPathComponent(baseName)
        var idx = 2
        while fm.fileExists(atPath: attempt.path) {
            attempt = parent.appendingPathComponent("\(baseName) \(idx)")
            idx += 1
            if idx > 1000 { break }   // sanity
        }
        try fm.createDirectory(at: attempt, withIntermediateDirectories: false, attributes: nil)
        return attempt
    }

    // MARK: New file (template)

    /// Create an empty file from a template kind. Skeleton matches
    /// the most common Windows Explorer "New > Text Document" /
    /// Finder "New File" affordance.
    @discardableResult
    static func createNewFile(
        in parent: URL,
        baseName: String,
        extension ext: String,
        contents: Data? = nil
    ) throws -> URL {
        let fm = FileManager.default
        var attempt = parent.appendingPathComponent("\(baseName).\(ext)")
        var idx = 2
        while fm.fileExists(atPath: attempt.path) {
            attempt = parent.appendingPathComponent("\(baseName) \(idx).\(ext)")
            idx += 1
            if idx > 1000 { break }
        }
        guard fm.createFile(atPath: attempt.path, contents: contents ?? Data(), attributes: nil) else {
            throw NSError(domain: "FileExplorer", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Could not create \u{201C}\(attempt.lastPathComponent)\u{201D}."
            ])
        }
        return attempt
    }

    // MARK: Copy / Move

    /// Copy or move a batch with progress reporting and conflict prompts.
    /// Runs on a detached task. Caller observes `progress` on the main thread.
    /// `move == true` deletes the source after a successful copy.
    static func transfer(
        _ sources: [URL],
        to destinationFolder: URL,
        move: Bool,
        progress: FileOperationProgress,
        resolver: @escaping ConflictResolver
    ) async {
        await MainActor.run {
            progress.reset()
            progress.total = sources.count
        }

        var blanketDecision: ConflictDecision? = nil
        // Accumulate per-item failures so a multi-file batch reports
        // EVERY failure, not just the last one to write `errorMessage`.
        var errors: [String] = []

        // Labelled so `.cancel` in the inner switch can abort the whole
        // batch — a bare `break` only escapes the switch and falls through
        // into the copy/move below, which is what the previous version did
        // by accident.
        batchLoop: for source in sources {
            if await MainActor.run(body: { progress.isCancelled }) { break }
            await MainActor.run { progress.currentFileName = source.lastPathComponent }

            var destination = destinationFolder.appendingPathComponent(source.lastPathComponent)

            // Bail on placing a folder inside itself (or into one of its
            // own descendants). Move would create an infinite loop on
            // disk; copy would either fail or recurse the freshly-
            // created destination back into itself, depending on
            // FileManager's exact traversal order — neither is
            // recoverable so we just refuse up front.
            if source == destinationFolder
                || destination.path.hasPrefix(source.path + "/") {
                let verb = move ? "move" : "copy"
                await MainActor.run {
                    progress.errorMessage = "Cannot \(verb) \u{201C}\(source.lastPathComponent)\u{201D} into itself."
                }
                break batchLoop
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                let decision: ConflictDecision
                if let cached = blanketDecision {
                    decision = cached
                } else {
                    let response = await resolver(source, destination)
                    decision = response.decision
                    if response.applyToAll { blanketDecision = response.decision }
                }
                switch decision {
                case .skip:
                    await MainActor.run { progress.processed += 1 }
                    continue
                case .cancel:
                    await MainActor.run { progress.isCancelled = true }
                    break batchLoop
                case .replace:
                    // Report (don't swallow) a removal failure — otherwise
                    // the following move/copy throws a misleading
                    // "file already exists" instead of the real
                    // permission/lock cause, and the user's Replace
                    // silently no-ops.
                    do {
                        try FileManager.default.removeItem(at: destination)
                    } catch {
                        errors.append("\(destination.lastPathComponent): couldn't replace — \(error.localizedDescription)")
                        await MainActor.run { progress.processed += 1 }
                        continue
                    }
                case .keepBoth:
                    destination = uniquify(destination)
                }
            }

            do {
                if move {
                    try FileManager.default.moveItem(at: source, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            } catch {
                errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
            await MainActor.run { progress.processed += 1 }
        }

        // Snapshot into a `let` before the @Sendable hand-off — the loop
        // above has already finished mutating `errors` by this point, but
        // Swift 6's strict concurrency checker can't prove that from a
        // captured `var`, so it flags the closure below as unsound
        // (matches the same fix already applied in TabViewModel's batch
        // rename).
        let finalErrors = errors
        await MainActor.run {
            progress.currentFileName = ""
            // Surface every failure, capped so a huge failed batch
            // doesn't produce an unreadable wall of text.
            if !finalErrors.isEmpty {
                let preview = finalErrors.prefix(8).joined(separator: "\n")
                let extra = finalErrors.count > 8 ? "\n…and \(finalErrors.count - 8) more." : ""
                progress.errorMessage = preview + extra
            }
            progress.isDone = true
        }
    }

    // MARK: Helpers

    /// Returns a new URL by appending the requested suffix (and a
    /// counter on subsequent collisions) until the path is free. Used
    /// for both "Keep Both" (" (copy)") and Duplicate (" copy").
    private static func uniquify(_ url: URL, suffix: String = " (copy)") -> URL {
        let parent = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let extPart = ext.isEmpty ? "" : ".\(ext)"
        var attempt = parent.appendingPathComponent("\(stem)\(suffix)\(extPart)")
        var idx = 2
        while FileManager.default.fileExists(atPath: attempt.path) {
            attempt = parent.appendingPathComponent("\(stem)\(suffix) \(idx)\(extPart)")
            idx += 1
            if idx > 1000 { break }
        }
        return attempt
    }
}
