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
    case merge
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
#if !CORE_TESTS
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

                let canMerge = FileSystemService.isReadableDirectory(source)
                    && FileSystemService.isReadableDirectory(destination)
                    && (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                    && (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                if canMerge { alert.addButton(withTitle: "Merge Folders") }
                let response = alert.runModal()
                let applyToAll = (alert.suppressionButton?.state == .on)
                let decision: ConflictDecision
                switch response {
                case .alertFirstButtonReturn:  decision = .replace
                case .alertSecondButtonReturn: decision = .keepBoth
                case .alertThirdButtonReturn:  decision = .skip
                case NSApplication.ModalResponse(rawValue: 1004): decision = .merge
                default:                       decision = .cancel
                }
                return (decision: decision, applyToAll: applyToAll)
            }
        }
    }
}

#endif

// MARK: - Progress

@MainActor
final class FileOperationProgress: ObservableObject {
    @Published var currentFileName: String = ""
    @Published var processed: Int = 0
    @Published var total: Int = 0
    @Published var isCancelled: Bool = false
    @Published var isDone: Bool = false
    @Published var errorMessage: String? = nil
    @Published var resultMessages: [String] = []
    @Published var succeeded: Int = 0
    @Published var skipped: Int = 0
    @Published var failedSources: [URL] = []
    @Published var completedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var availableBytes: Int64? = nil
    nonisolated let control = OperationControl()
    private var sampler: Task<Void, Never>?
    var bytesPerSecond: Double? {
        guard let startedAt else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed > 1 && completedBytes > 0 ? Double(completedBytes) / elapsed : nil
    }
    func startSampling() {
        startedAt = Date()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                let bytes = self.control.bytes
                self.completedBytes = bytes.done; self.totalBytes = bytes.total
                if self.isDone { return }
            }
        }
    }
    func finish(errors: [String]) {
        sampler?.cancel(); sampler = nil
        let bytes = control.bytes; completedBytes = bytes.done; totalBytes = bytes.total
        resultMessages += errors
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        currentFileName = ""; isDone = true
    }

    /// Set when the transfer actually begins (first processed item),
    /// so the rate / ETA estimates don't include the user's "Apply to
    /// all" thinking time.
    private var startedAt: Date? = nil

    func fraction(at now: Date = Date()) -> Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        return total > 0 ? Double(processed) / Double(total) : 0
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

    func cancel() { isCancelled = true; control.cancel() }
    func reset() {
        sampler?.cancel(); sampler = nil
        resultMessages = []; succeeded = 0; skipped = 0
        completedBytes = 0; totalBytes = 0
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
                #if !CORE_TESTS
                if let trash = result as URL? { TrashService.remember(original: url, trash: trash) }
                #endif
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
        try SafeFiles.validateName(trimmed)
        let parent = url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(trimmed)
        guard newURL.path != url.path else { return url }
        if SafeFiles.sameItem(url, newURL) {
            let temporary = parent.appendingPathComponent(".__fe_rename_" + UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: temporary)
            do { try FileManager.default.moveItem(at: temporary, to: newURL) }
            catch {
                do { try FileManager.default.moveItem(at: temporary, to: url) }
                catch { throw SafeFiles.error("Rename recovery item: \(temporary.path)") }
                throw error
            }
            return newURL
        }
        if SafeFiles.exists(newURL) {
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
        do {
            try (contents ?? Data()).write(to: attempt, options: .withoutOverwriting)
        } catch {
            throw NSError(domain: "FileExplorer", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Could not create \u{201C}\(attempt.lastPathComponent)\u{201D}."
            ])
        }
        return attempt
    }

    // MARK: Copy / Move

    /// Staging and committing are separate: failed/cancelled copies cannot
    /// damage an existing destination. All windows share the operation queue.
    @discardableResult
    static func transfer(
        _ sources: [URL], to destinationFolder: URL, move: Bool,
        progress: FileOperationProgress, resolver: @escaping ConflictResolver
    ) async -> [TransferRecord] {
        let capacity = try? destinationFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        await MainActor.run { progress.total = sources.count; progress.availableBytes = capacity; progress.startSampling() }
        let control = progress.control
        var records: [TransferRecord] = []
        var errors: [String] = []
        do {
            await MainActor.run { progress.currentFileName = "Waiting for other file operations…" }
            try await OperationQueue.shared.acquire(control)
        } catch {
            await MainActor.run { progress.finish(errors: []) }
            return []
        }
        for source in sources {
            if control.isCancelled { break }
            do { control.plan(try SafeFiles.logicalSize(source, control: control)) }
            catch { /* The item operation below reports the concrete failure. */ }
        }
        var blanket: ConflictDecision?
        for source in sources {
            if control.isCancelled { break }
            await MainActor.run { progress.currentFileName = source.lastPathComponent }
            do {
                try await transferOne(source, to: destinationFolder.appendingPathComponent(source.lastPathComponent),
                                      move: move, progress: progress, resolver: resolver,
                                      blanket: &blanket, records: &records)
            } catch is CancellationError { break }
            catch {
                errors.append("\(source.lastPathComponent): \(error.localizedDescription)")
                await MainActor.run { progress.failedSources.append(source) }
            }
            await MainActor.run { progress.processed += 1 }
        }
        await OperationQueue.shared.release()
        let finalErrors = errors
        await MainActor.run { progress.finish(errors: finalErrors) }
        return records
    }

    private static func transferOne(_ source: URL, to proposed: URL, move: Bool,
                                    progress: FileOperationProgress, resolver: @escaping ConflictResolver,
                                    blanket: inout ConflictDecision?, records: inout [TransferRecord]) async throws {
        let control = progress.control
        try control.check()
        let originalIdentity = try FileSnapshot(source, control: control)
        var destination = proposed
        let directory = (try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
        if SafeFiles.sameItem(source, destination) {
            if move {
                await MainActor.run { progress.skipped += 1; progress.resultMessages.append("Unchanged: \(source.path)") }
                return
            }
            destination = SafeFiles.unique(destination.deletingLastPathComponent().appendingPathComponent(
                source.deletingPathExtension().lastPathComponent + " (copy)" + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)))
        }
        if directory?.isDirectory == true, directory?.isSymbolicLink != true,
           SafeFiles.isInside(destination.deletingLastPathComponent(), source) {
            throw SafeFiles.error("Cannot transfer a folder into itself, including through a link.")
        }
        var expected = try? FileIdentity(destination)
        if expected != nil {
            let decision: ConflictDecision
            if let blanket { decision = blanket }
            else {
                let response = await resolver(source, destination)
                decision = response.decision
                if response.applyToAll, response.decision != .merge { blanket = response.decision }
            }
            try control.check()
            switch decision {
            case .cancel: await MainActor.run { progress.cancel() }; throw CancellationError()
            case .skip:
                await MainActor.run { progress.skipped += 1; progress.resultMessages.append("Skipped: \(source.path)") }
                return
            case .keepBoth: destination = SafeFiles.unique(destination); expected = nil
            case .replace: break
            case .merge:
                guard directory?.isDirectory == true, directory?.isSymbolicLink != true,
                      (try destination.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                      (try destination.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                    throw SafeFiles.error("Merge requires two real folders.")
                }
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for child in children {
                    try await transferOne(child, to: destination.appendingPathComponent(child.lastPathComponent),
                                          move: move, progress: progress, resolver: resolver,
                                          blanket: &blanket, records: &records)
                }
                // Keep the source directory so Undo always has a stable parent.
                return
            }
        }
        let fm = FileManager.default
        let workspace = try SafeFiles.privateDirectory(in: destination.deletingLastPathComponent())
        let staged = workspace.appendingPathComponent("incoming")
        defer {
            // Never remove a previous target preserved after a failed commit.
            if !SafeFiles.exists(workspace.appendingPathComponent("previous")) { try? fm.removeItem(at: workspace) }
        }
        // Same-volume moves can commit by rename: no duplicate data and
        // no long uncancellable recursive removal. Replacement still retains
        // its old target in the private recovery directory.
        if move, let parentIdentity = try? FileIdentity(destination.deletingLastPathComponent()),
           parentIdentity.device == originalIdentity.entries[""]?.device {
            try control.check()
            let backup = try MutationLock.withLock {
                guard try FileSnapshot(source, control: control) == originalIdentity else { throw SafeFiles.error("Source changed; move was not performed.") }
                return try SafeFiles.install(source, at: destination, replacing: expected, workspace: workspace)
            }
            let record = try TransferRecord(source: source, destination: destination, move: true, backup: backup)
            records.append(record)
            control.add((try? SafeFiles.logicalSize(destination, control: OperationControl())) ?? 0)
            let actual = destination
            await MainActor.run {
                progress.succeeded += 1; progress.resultMessages.append("Moved: \(actual.path)")
                if let backup { progress.resultMessages.append("Previous item preserved: \(backup.path)") }
            }
            return
        }
        try SafeFiles.copy(source, to: staged, control: control)
        try control.check()
        guard try FileSnapshot(source, control: control) == originalIdentity else { throw SafeFiles.error("Source changed during transfer; destination was not changed.") }
        var retiredSource: URL?
        if move {
            retiredSource = try MutationLock.withLock {
                guard try FileSnapshot(source, control: control) == originalIdentity else { throw SafeFiles.error("Source changed; source was preserved.") }
                let retired = try SafeFiles.retire(source)
                do {
                    guard try FileSnapshot(retired, control: control) == originalIdentity else { throw SafeFiles.error("Source changed during retirement.") }
                } catch {
                    do { try fm.moveItem(at: retired, to: source) }
                    catch { throw SafeFiles.error("Source recovery required at \(retired.path)") }
                    throw error
                }
                return retired
            }
        }
        let backup: URL?
        do {
            backup = try SafeFiles.install(staged, at: destination, replacing: expected, workspace: workspace)
        } catch {
            if let retiredSource {
                do { try fm.moveItem(at: retiredSource, to: source) }
                catch { throw SafeFiles.error("Source recovery required at \(retiredSource.path). Destination recovery: \(workspace.path)") }
            }
            throw error
        }
        let record = try TransferRecord(source: source, destination: destination, move: move, backup: backup)
        records.append(record)
        let actual = destination
        let preservedSource = retiredSource
        await MainActor.run {
            progress.succeeded += 1; progress.resultMessages.append("Transferred: \(actual.path)")
            if let backup { progress.resultMessages.append("Previous item preserved: \(backup.path)") }
            if let preservedSource { progress.resultMessages.append("Source recovery copy: \(preservedSource.path)") }
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
