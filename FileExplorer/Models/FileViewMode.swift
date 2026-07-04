//
//  FileViewMode.swift
//  FileExplorer
//
//  How the file list is rendered. Three modes for now; Windows offers
//  eight (extra-large/large/medium/small icons + list + details + tiles
//  + content), which is too much choice for an MVP.
//

import Foundation

enum FileViewMode: String, CaseIterable, Identifiable {
    case extraLargeIcons = "xlicons"   // Windows Explorer "Extra Large Icons"
    case icons   = "icons"             // grid of large icons + filename below
    case list    = "list"              // compact one-line rows (no columns)
    case details = "details"           // table — Name / Date / Type / Size (default)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extraLargeIcons: return "Extra Large Icons"
        case .icons:           return "Icons"
        case .list:            return "List"
        case .details:         return "Details"
        }
    }

    var symbol: String {
        switch self {
        case .extraLargeIcons: return "square.grid.3x3"
        case .icons:           return "square.grid.2x2"
        case .list:            return "list.bullet"
        case .details:         return "list.dash.header.rectangle"
        }
    }

    /// Pixel size of the icon image for grid-style modes. Used by
    /// IconsGridView to render the same view at two sizes without
    /// having a second View struct.
    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: return 96
        case .icons:           return 56
        case .list, .details:  return 16
        }
    }

    /// Adaptive column min/max for the LazyVGrid in icon modes.
    var gridColumnMin: CGFloat {
        switch self {
        case .extraLargeIcons: return 160
        case .icons:           return 110
        default:               return 110
        }
    }

    var gridColumnMax: CGFloat {
        switch self {
        case .extraLargeIcons: return 200
        case .icons:           return 130
        default:               return 130
        }
    }
}
