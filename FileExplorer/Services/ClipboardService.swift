//
//  ClipboardService.swift
//  FileExplorer
//
//  Tracks the user's Cut / Copy intent across windows so a subsequent
//  Paste in the same tab (or any tab) knows what to do. Cut items render
//  with reduced opacity in the file list (matching Windows Explorer's
//  faded-on-cut behaviour) until the user pastes or clears the clipboard.
//
//  This is intentionally separate from `NSPasteboard` because:
//   - We need to detect "cut" vs "copy" reliably, and the system
//     pasteboard doesn't carry that flag without custom UTIs.
//   - We need to clear cut state when the move completes.
//

import Foundation
import AppKit
import Combine

@MainActor
final class ClipboardService: ObservableObject {

    static let shared = ClipboardService()

    enum Mode { case copy, cut }

    @Published private(set) var urls: [URL] = []
    @Published private(set) var mode: Mode = .copy

    /// `NSPasteboard.general.changeCount` at the moment WE last wrote
    /// it. If the system pasteboard has changed since (the user copied
    /// something in Finder or any other app), our internal clipboard is
    /// stale and Paste must prefer the system contents — otherwise ⌘V
    /// would paste files the user copied minutes ago instead of what
    /// they just copied elsewhere.
    private var writtenChangeCount: Int = -1

    private init() {}

    // MARK: API

    func copy(_ urls: [URL]) {
        self.urls = urls
        self.mode = .copy
        writeFileURLsToPasteboard(urls)
    }

    func cut(_ urls: [URL]) {
        self.urls = urls
        self.mode = .cut
        writeFileURLsToPasteboard(urls)
    }

    func clear() {
        urls.removeAll()
        // If the system pasteboard still holds what we wrote (a CUT
        // that just completed), clear it too — otherwise the next ⌘V
        // would try to copy files that were just moved away.
        let pb = NSPasteboard.general
        if pb.changeCount == writtenChangeCount {
            pb.clearContents()
            writtenChangeCount = pb.changeCount
        }
    }

    /// Whether a given URL is currently in the clipboard as a CUT item.
    /// Used by the file list to render it translucent.
    func isCutMarked(_ url: URL) -> Bool {
        mode == .cut && urls.contains(url)
    }

    /// True if there is anything available to paste right now — ours,
    /// or file URLs another app (Finder…) put on the system pasteboard.
    var hasContent: Bool {
        let pb = NSPasteboard.general
        if !urls.isEmpty, pb.changeCount == writtenChangeCount { return true }
        return pb.canReadObject(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true])
    }

    /// What a Paste should act on right now:
    ///  • the internal clipboard, when the system pasteboard still holds
    ///    what we wrote (this preserves Cut = move semantics), or
    ///  • file URLs somebody else put on the system pasteboard since
    ///    (always a COPY — we can't know their cut intent).
    /// nil when neither offers files — e.g. the user copied TEXT after
    /// copying files here; pasting the stale files would be surprising.
    func resolvePasteContents() -> (urls: [URL], move: Bool)? {
        let pb = NSPasteboard.general
        if !urls.isEmpty, pb.changeCount == writtenChangeCount {
            return (urls, mode == .cut)
        }
        let external = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !external.isEmpty else { return nil }
        return (external, false)
    }

    /// Mirror Cut/Copy onto the system pasteboard so the files can be
    /// pasted in Finder (and any other app that reads file URLs).
    private func writeFileURLsToPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        writtenChangeCount = pb.changeCount
    }

    // MARK: - System pasteboard (path strings)

    /// Write the supplied URLs' POSIX paths to the system pasteboard,
    /// newline-separated. Independent of the Cut/Copy state above —
    /// this is the "Copy as Pathname" action that puts plain text on
    /// the clipboard so other apps (Terminal, editors) can paste it.
    static func copyPathsToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let joined = urls.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
    }
}
