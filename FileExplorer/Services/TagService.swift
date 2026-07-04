//
//  TagService.swift
//  FileExplorer
//
//  Read / write macOS Finder tags via `URLResourceKey.tagNamesKey`.
//  Tag names are user-defined strings; the system maps a handful of
//  reserved names to colours (Red / Orange / Yellow / Green / Blue /
//  Purple / Gray). The Finder respects these mappings, so anything we
//  write here shows up identically there.
//

import Foundation
import AppKit

enum TagService {

    /// The seven canonical colour-coded tags shown in Finder. Stored as
    /// localised names — these match what `tagNamesKey` returns.
    static let standardTags: [(name: String, color: NSColor)] = [
        ("Red",    .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green",  .systemGreen),
        ("Blue",   .systemBlue),
        ("Purple", .systemPurple),
        ("Gray",   .systemGray),
    ]

    static func tagNames(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey])
              .tagNames) ?? []
    }

    /// Replace the tag list on `url`. Pass an empty array to clear.
    /// `URLResourceValues.tagNames` is read-only in Swift; we go through
    /// `(url as NSURL).setResourceValue` which accepts the same key.
    @discardableResult
    static func setTagNames(_ names: [String], on url: URL) -> Bool {
        do {
            try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
            return true
        } catch {
            NSLog("setTagNames failed for \(url.path): \(error)")
            return false
        }
    }

    /// Add or remove a single tag (toggle).
    static func toggleTag(_ name: String, on urls: [URL]) {
        for url in urls {
            var tags = tagNames(of: url)
            if let idx = tags.firstIndex(of: name) {
                tags.remove(at: idx)
            } else {
                tags.append(name)
            }
            _ = setTagNames(tags, on: url)
        }
    }

    /// Look up the colour for a standard tag name (case-insensitive).
    /// Returns `nil` for custom user-defined tag names — those render
    /// with the generic gray bullet.
    static func color(for tagName: String) -> NSColor? {
        let lowered = tagName.lowercased()
        return standardTags.first { $0.name.lowercased() == lowered }?.color
    }
}
