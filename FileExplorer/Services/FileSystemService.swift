//
//  FileSystemService.swift
//  FileExplorer
//
//  Directory listing. Future Sprints add: file watching (FSEvents),
//  copy/move/delete with progress, trash operations.
//

import Foundation

/// Surface-friendly errors so the file list's empty state can show the
/// user something more actionable than "cocoaError 257". macOS-specific:
/// kPOSIXErrorEPERM (1) and kPOSIXErrorEACCES (13) are the two error
/// codes TCC and POSIX file modes raise.
enum FileSystemServiceError: LocalizedError {
    case permissionDenied(URL, isTCCProtected: Bool)
    case notADirectory(URL)
    case missing(URL)
    case other(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let url, let isTCC):
            if isTCC {
                return "macOS is blocking access to \u{201C}\(url.lastPathComponent)\u{201D}. Grant Full Disk Access to FileExplorer in System Settings → Privacy & Security."
            }
            return "You don't have permission to read \u{201C}\(url.lastPathComponent)\u{201D}."
        case .notADirectory(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D} is not a folder."
        case .missing(let url):
            return "\u{201C}\(url.lastPathComponent)\u{201D} doesn't exist anymore."
        case .other(_, let underlying):
            return underlying.localizedDescription
        }
    }
}

enum FileSystemService {

    /// Read the contents of a directory URL into `FileItem`s. Throws on
    /// permission denied or non-directory paths.
    static func listDirectory(at url: URL, includeHidden: Bool = false) throws -> [FileItem] {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentAccessDateKey,
            .typeIdentifierKey, .nameKey, .tagNamesKey,
        ]

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            // Convert raw POSIX / Cocoa errors into a typed payload the
            // UI can branch on (permission vs missing vs other).
            throw mapError(error, for: url)
        }

        return children.compactMap { childURL -> FileItem? in
            let values = try? childURL.resourceValues(forKeys: Set(resourceKeys))
            let isDir = values?.isDirectory ?? false
            let isPkg = values?.isPackage ?? false
            return FileItem(
                id: childURL,
                url: childURL,
                name: values?.name ?? childURL.lastPathComponent,
                isDirectory: isDir,
                isPackage: isPkg,
                isHidden: values?.isHidden ?? false,
                isSymlink: values?.isSymbolicLink ?? false,
                size: isDir ? nil : Int64(values?.fileSize ?? 0),
                dateModified: values?.contentModificationDate,
                dateCreated: values?.creationDate,
                dateAccessed: values?.contentAccessDate,
                typeIdentifier: values?.typeIdentifier,
                tagNames: values?.tagNames ?? []
            )
        }
    }

    /// Returns true if URL points to a readable directory.
    static func isReadableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }

    /// Heuristic: paths macOS gates behind Full Disk Access (or that
    /// otherwise require special entitlements). When the user gets
    /// permission denied on one of these we tell them where to grant
    /// FileExplorer FDA instead of leaving them staring at a generic
    /// "permission denied".
    static func isTCCProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let prefixes = [
            "/Library/Application Support",
            "/private/var/db",
            "/System",
            NSHomeDirectory() + "/Library",
            NSHomeDirectory() + "/.Trash",
        ]
        return prefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func mapError(_ error: Error, for url: URL) -> FileSystemServiceError {
        let nsErr = error as NSError
        // Cocoa permission errors: NSCocoaErrorDomain 257 (no read perms)
        // POSIX EPERM = 1, EACCES = 13.
        if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoPermissionError {
            return .permissionDenied(url, isTCCProtected: isTCCProtected(url))
        }
        if nsErr.domain == NSPOSIXErrorDomain && (nsErr.code == 1 || nsErr.code == 13) {
            return .permissionDenied(url, isTCCProtected: isTCCProtected(url))
        }
        if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadNoSuchFileError {
            return .missing(url)
        }
        if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileReadUnknownError {
            // Often happens when target is a regular file, not a directory.
            return .notADirectory(url)
        }
        return .other(url, underlying: error)
    }
}
