//
//  ArchiveService.swift
//  FileExplorer
//
//  ZIP compression / extraction via macOS's `ditto` tool. We use ditto
//  (not /usr/bin/zip) because it:
//    • Preserves extended attributes, ACLs and resource forks
//    • Matches Finder's "Compress" output exactly
//    • Is part of the base system, no extra dependencies
//
//  Both operations run in a detached process and report progress
//  through a `FileOperationProgress` so the existing ProgressDialog
//  can be reused.
//

import Foundation

enum ArchiveError: LocalizedError {
    case toolFailed(String)
    case noItems
    var errorDescription: String? {
        switch self {
        case .toolFailed(let m): return m
        case .noItems: return "No items selected to compress."
        }
    }
}

enum ArchiveService {

    // MARK: - Compress

    /// Compress one or more files / folders into a single .zip placed
    /// alongside the first source. The destination's name is derived
    /// from the source (single item) or labelled "Archive.zip" (multiple).
    static func compress(
        _ sources: [URL],
        progress: FileOperationProgress
    ) async {
        await MainActor.run {
            progress.reset()
            progress.total = sources.count
        }
        guard let first = sources.first else {
            await MainActor.run {
                progress.errorMessage = ArchiveError.noItems.localizedDescription
                progress.isDone = true
            }
            return
        }
        let parent = first.deletingLastPathComponent()

        let zipURL: URL
        if sources.count == 1 {
            let stem = first.deletingPathExtension().lastPathComponent
            zipURL = uniqueURL(in: parent, candidate: "\(stem).zip")
        } else {
            zipURL = uniqueURL(in: parent, candidate: "Archive.zip")
        }

        do {
            // ditto can only zip a single source at a time, so for
            // multi-selection we stage the items into a temp folder
            // first and zip the folder. Finder does the same.
            let staging: URL? = (sources.count > 1) ? try makeStaging(for: sources) : nil
            let inputURL = staging ?? first

            try await runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent",
                            inputURL.path, zipURL.path]
            )

            if let staging = staging {
                try? FileManager.default.removeItem(at: staging)
            }

            await MainActor.run {
                progress.processed = progress.total
                progress.isDone = true
            }
        } catch {
            await MainActor.run {
                progress.errorMessage = error.localizedDescription
                progress.isDone = true
            }
        }
    }

    // MARK: - Extract

    /// Extract a supported archive into the directory it lives in.
    /// Format dispatch:
    ///   • .zip                — ditto -xk
    ///   • .tar / .tar.gz / .tgz / .tar.bz2 / .tbz — /usr/bin/tar -xf
    /// Anything else gets a "Format not supported" error so the user
    /// knows to install a 7z / RAR tool externally.
    static func extract(
        _ archive: URL,
        progress: FileOperationProgress
    ) async {
        await MainActor.run {
            progress.reset()
            progress.total = 1
            progress.currentFileName = archive.lastPathComponent
        }
        let destination = archive.deletingLastPathComponent()
        let lowerName = archive.lastPathComponent.lowercased()
        do {
            if lowerName.hasSuffix(".zip") {
                try await runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: ["-x", "-k", archive.path, destination.path]
                )
            } else if lowerName.hasSuffix(".tar")
                || lowerName.hasSuffix(".tar.gz")
                || lowerName.hasSuffix(".tgz")
                || lowerName.hasSuffix(".tar.bz2")
                || lowerName.hasSuffix(".tbz")
                || lowerName.hasSuffix(".tar.xz")
                || lowerName.hasSuffix(".txz") {
                // `/usr/bin/tar` on macOS auto-detects gzip/bzip2/xz
                // compression — no per-suffix flag needed.
                try await runProcess(
                    executable: "/usr/bin/tar",
                    arguments: ["-x", "-f", archive.path, "-C", destination.path]
                )
            } else {
                throw ArchiveError.toolFailed(
                    "Unsupported archive format: \(archive.pathExtension). " +
                    "Try uncompressing it from Finder or with a dedicated tool."
                )
            }
            await MainActor.run {
                progress.processed = 1
                progress.isDone = true
            }
        } catch {
            await MainActor.run {
                progress.errorMessage = error.localizedDescription
                progress.isDone = true
            }
        }
    }

    // MARK: - Helpers

    /// Generic helper to launch a command-line tool and await its
    /// completion. Used for both `ditto` (compress/extract zip) and
    /// `tar` (extract tar/tar.gz/...). Errors carry stderr.
    private static func runProcess(
        executable: String,
        arguments: [String]
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let errPipe = Pipe()
            process.standardError = errPipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let toolName = (executable as NSString).lastPathComponent
                    let msg = String(data: data, encoding: .utf8) ?? "\(toolName) exited \(proc.terminationStatus)"
                    continuation.resume(throwing: ArchiveError.toolFailed(msg))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Build a unique zip path — if "X.zip" exists, try "X 2.zip", "X 3.zip"…
    private static func uniqueURL(in parent: URL, candidate: String) -> URL {
        var url = parent.appendingPathComponent(candidate)
        var idx = 2
        let stem = (candidate as NSString).deletingPathExtension
        let ext  = (candidate as NSString).pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(stem) \(idx)" + (ext.isEmpty ? "" : ".\(ext)"))
            idx += 1
            if idx > 1000 { break }
        }
        return url
    }

    /// Stage multi-selection items into a temp folder so ditto can zip
    /// them as a single archive. Items inside the staging folder are
    /// hard-linked (cheap; same volume), or copied when crossing volumes.
    private static func makeStaging(for urls: [URL]) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for url in urls {
            let target = temp.appendingPathComponent(url.lastPathComponent)
            // Try a hard link first (instant); fall back to copy.
            do {
                try FileManager.default.linkItem(at: url, to: target)
            } catch {
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
        return temp
    }
}
