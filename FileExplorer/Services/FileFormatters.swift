//
//  FileFormatters.swift
//  FileExplorer
//
//  Shared formatters reused by every file-list cell. DateFormatter is
//  surprisingly expensive to construct (string-table lookups, locale
//  resolution) — instantiating one per cell row per redraw was visible
//  on long folders. These cached instances stay in memory for the life
//  of the app and serve all renders.
//

import Foundation

enum FileFormatters {

    /// Short date + short time. Matches the column-cell format used by
    /// Details / Grouped views. DateFormatter is Sendable in modern
    /// Foundation so a single shared instance is safe across threads.
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// Long date + medium time — used by PropertiesDialog.
    static let longDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    /// Format a possibly-nil date with the short formatter. Returns "—"
    /// for nil so cells stay aligned with the rest of the column.
    static func short(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return shortDateTime.string(from: date)
    }

    static func long(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        return longDateTime.string(from: date)
    }
}
