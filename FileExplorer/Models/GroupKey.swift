//
//  GroupKey.swift
//  FileExplorer
//
//  Windows-Explorer-style grouping. When the user picks "Group by …"
//  the file list switches from a flat table to sectioned rows under
//  category headers. Each key has its own bucketing function.
//

import Foundation
import UniformTypeIdentifiers

enum GroupKey: String, CaseIterable, Identifiable {
    case none = "none"
    case type = "type"
    case dateModified = "date"
    case size = "size"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:         return "None"
        case .type:         return "Type"
        case .dateModified: return "Date Modified"
        case .size:         return "Size"
        }
    }

    /// Returns the bucket label for an item under this grouping. Items
    /// with the same label appear in the same section.
    func bucket(for item: FileItem) -> String {
        switch self {
        case .none:
            return ""
        case .type:
            if item.isDirectory && !item.isPackage { return "Folder" }
            return typeBucket(for: item)
        case .dateModified:
            return dateBucket(for: item.dateModified)
        case .size:
            return sizeBucket(for: item)
        }
    }

    /// Stable ordering of the section headers (so "Folder" always comes
    /// before "Image", "Today" before "Yesterday", etc.). Lower numbers
    /// render first.
    func sortOrder(of bucket: String) -> Int {
        switch self {
        case .none:
            return 0
        case .type:
            return Self.typeOrder[bucket] ?? 99
        case .dateModified:
            return Self.dateOrder[bucket] ?? 99
        case .size:
            return Self.sizeOrder[bucket] ?? 99
        }
    }

    // MARK: - Bucketing helpers

    private static let typeOrder: [String: Int] = [
        "Folder": 0, "Image": 1, "Document": 2, "Video": 3,
        "Audio": 4, "Archive": 5, "Code": 6, "Other": 99
    ]
    private static let dateOrder: [String: Int] = [
        "Today": 0, "Yesterday": 1, "Last 7 Days": 2,
        "Last 30 Days": 3, "Earlier This Year": 4, "Older": 5, "Unknown": 99
    ]
    private static let sizeOrder: [String: Int] = [
        "Empty (0 KB)": 0, "Tiny (< 100 KB)": 1, "Small (< 1 MB)": 2,
        "Medium (< 16 MB)": 3, "Large (< 128 MB)": 4, "Huge (≥ 128 MB)": 5,
        "Folder": 6
    ]

    private func typeBucket(for item: FileItem) -> String {
        guard let utiID = item.typeIdentifier,
              let ut = UTType(utiID) else { return "Other" }
        if ut.conforms(to: .image) { return "Image" }
        if ut.conforms(to: .movie) || ut.conforms(to: .video) { return "Video" }
        if ut.conforms(to: .audio) { return "Audio" }
        if ut.conforms(to: .archive) { return "Archive" }
        if ut.conforms(to: .sourceCode) { return "Code" }
        if ut.conforms(to: .text) || ut.conforms(to: .pdf)
            || ut.conforms(to: .spreadsheet) || ut.conforms(to: .presentation)
            || ut.conforms(to: .content) { return "Document" }
        return "Other"
    }

    private func dateBucket(for date: Date?) -> String {
        guard let date = date else { return "Unknown" }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let week = cal.date(byAdding: .day, value: -7, to: now), date >= week {
            return "Last 7 Days"
        }
        if let month = cal.date(byAdding: .day, value: -30, to: now), date >= month {
            return "Last 30 Days"
        }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return "Earlier This Year"
        }
        return "Older"
    }

    private func sizeBucket(for item: FileItem) -> String {
        if item.isDirectory && !item.isPackage { return "Folder" }
        let bytes = item.size ?? 0
        switch bytes {
        case 0:                            return "Empty (0 KB)"
        case 1..<102_400:                  return "Tiny (< 100 KB)"
        case 102_400..<1_048_576:          return "Small (< 1 MB)"
        case 1_048_576..<16_777_216:       return "Medium (< 16 MB)"
        case 16_777_216..<134_217_728:     return "Large (< 128 MB)"
        default:                           return "Huge (≥ 128 MB)"
        }
    }
}
