//
//  FileItem.swift
//  FileExplorer
//
//  Lazily-built metadata for a single directory entry. The `URL` is the
//  source of truth — every other field is derived (and refreshed only
//  when the directory listing is rebuilt).
//

import Foundation
import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id: URL              // unique within a directory listing
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool      // .app, .rtfd, etc. treated as files in Finder
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64?         // nil for directories (lazy compute on demand)
    let dateModified: Date?
    let dateCreated: Date?
    /// "Last opened" / "Date Accessed" — populated by the kernel on
    /// file open. Surfaced as an optional column.
    let dateAccessed: Date?
    let typeIdentifier: String?   // e.g. "public.png"
    /// Finder tag names captured at listing time so the file list
    /// doesn't go back to disk on every row redraw.
    let tagNames: [String]

    /// User-facing display name without leading dot when not showing hidden.
    var displayName: String { name }

    /// Filename to render in the UI. When `showingExtensions` is false
    /// we strip the file extension (matching Finder's / Explorer's
    /// "hide known extensions" mode) but leave folders and dot-prefixed
    /// names like `.DS_Store` unchanged — for those the "extension"
    /// IS the name.
    func displayName(showingExtensions: Bool) -> String {
        if showingExtensions { return name }
        if isDirectory && !isPackage { return name }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// "Type" column text — e.g. "Folder", "PNG image", "Plain text".
    var typeLabel: String {
        if isDirectory && !isPackage { return "Folder" }
        if let utiID = typeIdentifier,
           let ut = UTType(utiID),
           let description = ut.localizedDescription {
            return description
        }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased() + " file"
    }

    /// File-system icon resolved via NSWorkspace. NSWorkspace caches
    /// these internally, so the call is cheap even when invoked from
    /// view-rebuild paths.
    var systemIcon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Build a FileItem on demand from a bare URL — used for Spotlight
    /// search results which arrive as paths only. Returns `nil` if the
    /// URL doesn't exist on disk.
    static func from(url: URL) -> FileItem? {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .creationDateKey,
            .contentAccessDateKey,
            .typeIdentifierKey, .nameKey, .tagNamesKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return nil
        }
        let isDir = values.isDirectory ?? false
        let isPkg = values.isPackage ?? false
        return FileItem(
            id: url,
            url: url,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDir,
            isPackage: isPkg,
            isHidden: values.isHidden ?? false,
            isSymlink: values.isSymbolicLink ?? false,
            size: isDir ? nil : Int64(values.fileSize ?? 0),
            dateModified: values.contentModificationDate,
            dateCreated: values.creationDate,
            dateAccessed: values.contentAccessDate,
            typeIdentifier: values.typeIdentifier,
            tagNames: values.tagNames ?? []
        )
    }
}

// MARK: - Sort keys

extension FileItem {
    /// Sort options exposed in the View menu and per-view context menus.
    /// Ordered to match Finder's own "Sort By" submenu so muscle memory
    /// from macOS users transfers. New cases auto-populate every menu —
    /// they all iterate `SortKey.allCases`.
    enum SortKey: String, CaseIterable, Identifiable {
        case name             = "Name"
        case typeLabel        = "Kind"
        case dateLastOpened   = "Date Last Opened"
        case dateModified     = "Date Modified"
        case dateCreated      = "Date Created"
        case size             = "Size"
        case tags             = "Tags"
        var id: String { rawValue }
    }
}
