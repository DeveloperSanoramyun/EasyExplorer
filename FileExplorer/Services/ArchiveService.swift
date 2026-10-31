import Foundation
import Darwin

// libarchive is part of macOS. Only the reader API is used: extraction writes
// regular files explicitly and never asks the library to apply archive paths,
// links, ownership, device nodes, ACLs or executable permission bits.

enum ArchiveError: LocalizedError {
    case toolFailed(String)
    case noItems
    var errorDescription: String? {
        switch self {
        case .toolFailed(let text): return text
        case .noItems: return "No items selected to compress."
        }
    }
}

enum ArchiveService {
    struct Limits {
        var entries = 100_000
        var bytes: Int64 = 20 * 1024 * 1024 * 1024
    }
    struct Entry: Identifiable {
        let id: String
        let size: Int64
        let isDirectory: Bool
    }
    static let supportedSuffixes = [".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tar.xz", ".txz", ".7z", ".rar"]
    static func supports(_ url: URL) -> Bool { supportedSuffixes.contains { url.lastPathComponent.lowercased().hasSuffix($0) } }

    static func compress(_ sources: [URL], progress: FileOperationProgress) async {
        let control = progress.control
        await MainActor.run { progress.total = sources.count; progress.startSampling() }
        var errors: [String] = []
        do { try await OperationQueue.shared.acquire(control) }
        catch { await MainActor.run { progress.finish(errors: []) }; return }
        do {
            guard let first = sources.first else { throw ArchiveError.noItems }
            let fm = FileManager.default
            let workspace = try SafeFiles.privateDirectory(in: first.deletingLastPathComponent())
            defer { try? fm.removeItem(at: workspace) }
            let input: URL
            if sources.count == 1 { input = first }
            else {
                input = workspace.appendingPathComponent("Archive")
                try fm.createDirectory(at: input, withIntermediateDirectories: false)
                for source in sources {
                    try control.check()
                    control.plan(try SafeFiles.logicalSize(source, control: control))
                    let target = SafeFiles.unique(input.appendingPathComponent(source.lastPathComponent))
                    try SafeFiles.copy(source, to: target, control: control)
                }
            }
            let staged = workspace.appendingPathComponent("output.zip")
            let result = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", input.path, staged.path], control: control)
            guard result.status == 0 else { throw ArchiveError.toolFailed(result.error) }
            try control.check()
            let name = sources.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
            let destination = SafeFiles.unique(first.deletingLastPathComponent().appendingPathComponent(name + ".zip"))
            _ = try SafeFiles.install(staged, at: destination, replacing: nil, workspace: workspace)
            await MainActor.run { progress.processed = progress.total; progress.succeeded = sources.count; progress.resultMessages.append("Created: \(destination.path)") }
        } catch is CancellationError { /* Partial archive and staging are removed by defer. */ }
        catch { errors.append(error.localizedDescription) }
        await OperationQueue.shared.release()
        let final = errors
        await MainActor.run { progress.finish(errors: final) }
    }

    /// One controller owns progress/errors for the WHOLE batch.
    static func extract(_ archives: [URL], progress: FileOperationProgress, selected: Set<String>? = nil) async {
        let control = progress.control
        await MainActor.run { progress.total = archives.count; progress.startSampling() }
        do { try await OperationQueue.shared.acquire(control) }
        catch { await MainActor.run { progress.finish(errors: []) }; return }
        var errors: [String] = []
        for archive in archives {
            if control.isCancelled { break }
            await MainActor.run { progress.currentFileName = archive.lastPathComponent }
            do {
                let destination = try extractOne(archive, control: control, selected: selected)
                await MainActor.run { progress.succeeded += 1; progress.resultMessages.append("Extracted: \(destination.path)") }
            } catch is CancellationError { break }
            catch {
                errors.append("\(archive.lastPathComponent): \(error.localizedDescription)")
                await MainActor.run { progress.failedSources.append(archive) }
            }
            await MainActor.run { progress.processed += 1 }
        }
        await OperationQueue.shared.release()
        let final = errors
        await MainActor.run { progress.finish(errors: final) }
    }

    static func extractOne(_ archive: URL, control: OperationControl, selected: Set<String>? = nil, limits: Limits = Limits()) throws -> URL {
        let fm = FileManager.default
        let workspace = try SafeFiles.privateDirectory(in: archive.deletingLastPathComponent())
        defer { try? fm.removeItem(at: workspace) }
        let contents = workspace.appendingPathComponent("contents")
        try fm.createDirectory(at: contents, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try read(archive, root: contents, selected: selected, control: control, limits: limits)
        try control.check()
        var name = archive.lastPathComponent
        if let suffix = supportedSuffixes.sorted(by: { $0.count > $1.count }).first(where: { name.lowercased().hasSuffix($0) }) { name.removeLast(suffix.count) }
        if name.isEmpty { name = "Extracted" }
        let destination = SafeFiles.unique(archive.deletingLastPathComponent().appendingPathComponent(name))
        _ = try SafeFiles.install(contents, at: destination, replacing: nil, workspace: workspace)
        return destination
    }

    static func list(_ archive: URL, control: OperationControl = OperationControl()) throws -> [Entry] {
        try read(archive, root: nil, selected: nil, control: control, limits: Limits())
    }

    private static func read(_ archive: URL, root: URL?, selected: Set<String>?, control: OperationControl, limits: Limits) throws -> [Entry] {
        guard let reader = archive_read_new() else { throw SafeFiles.error("Cannot initialize archive reader.") }
        defer { _ = archive_read_free(reader) }
        _ = archive_read_support_filter_all(reader); _ = archive_read_support_format_all(reader)
        func failure() -> NSError { SafeFiles.error(archive_error_string(reader).map { String(cString: $0) } ?? "Archive is damaged or encrypted.") }
        guard archive_read_open_filename(reader, archive.path, 65536) == 0 else { throw failure() }
        var entries: [Entry] = []
        var actualBytes: Int64 = 0
        var declaredBytes: Int64 = 0
        var seen: Set<String> = []
        var headerCount = 0
        let deadline = Date().addingTimeInterval(3600)
        while true {
            try control.check()
            guard Date() < deadline else { throw SafeFiles.error("Archive processing timed out.") }
            var raw: OpaquePointer?
            let status = archive_read_next_header(reader, &raw)
            if status == 1 { break } // ARCHIVE_EOF
            guard status == 0, let entry = raw else { throw failure() }
            headerCount += 1
            guard headerCount <= limits.entries else { throw SafeFiles.error("Archive exceeds the \(limits.entries)-entry limit.") }
            guard let path = archive_entry_pathname(entry), let name = String(validatingUTF8: path) else { throw SafeFiles.error("Invalid archive filename encoding.") }
            let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."), name.utf8.count <= 4096 else {
                throw SafeFiles.error("Unsafe archive path: \(name)")
            }
            let cleanParts = parts.filter { $0 != "." }
            let clean = cleanParts.joined(separator: "/")
            let type = archive_entry_filetype(entry)
            guard archive_entry_hardlink(entry) == nil, archive_entry_symlink(entry) == nil, type == 0o100000 || type == 0o040000 else {
                throw SafeFiles.error("Archive links and special files are not supported: \(name)")
            }
            if clean.isEmpty { continue }
            guard seen.insert(clean).inserted else { throw SafeFiles.error("Duplicate archive entry: \(clean)") }
            let size = archive_entry_size(entry)
            guard size >= 0, size <= limits.bytes - declaredBytes else { throw SafeFiles.error("Archive exceeds the \(limits.bytes)-byte extraction limit.") }
            declaredBytes += size
            let isDirectory = type == 0o040000
            entries.append(Entry(id: clean, size: size, isDirectory: isDirectory))
            guard let root else { continue }
            if let selected, !selected.contains(clean), !selected.contains(where: { clean.hasPrefix($0 + "/") }) { continue }
            let target = root.appendingPathComponent(clean)
            guard SafeFiles.isInside(target, root) else { throw SafeFiles.error("Archive path escapes the extraction folder.") }
            if isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                continue
            }
            control.plan(size)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // No archive entry can introduce symlinks; exclusive creation also
            // rejects case-insensitive aliases and collisions with directories.
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    try control.check()
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    guard count >= 0 else { throw failure() }
                    if count == 0 { break }
                    guard Int64(count) <= limits.bytes - actualBytes else { throw SafeFiles.error("Archive expanded beyond the extraction limit.") }
                    actualBytes += Int64(count)
                    try handle.write(contentsOf: Data(buffer.prefix(count)))
                    control.add(Int64(count))
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
        }
        return entries
    }
}
