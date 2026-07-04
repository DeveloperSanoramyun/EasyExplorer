//
//  ShareService.swift
//  FileExplorer
//
//  Bridges to macOS's standard Share menu (NSSharingServicePicker)
//  so the user can hand selected files off to AirDrop, Mail, Messages,
//  Notes, etc. — the same picker Finder's Share submenu uses.
//
//  The picker is anchored to a screen rect; in a SwiftUI context we
//  resolve that from the key window's coordinate space at trigger time.
//  Good-enough placement: top-leading of the active window, where the
//  menu was likely invoked.
//

import Foundation
import AppKit

@MainActor
enum ShareService {

    /// Pop the system Share sheet for the supplied files. Silent no-op
    /// when the URL list is empty or no key window is available.
    static func showPicker(for urls: [URL]) {
        guard !urls.isEmpty,
              let window = NSApp.keyWindow,
              let contentView = window.contentView
        else { return }

        let picker = NSSharingServicePicker(items: urls)
        // Show under the top-leading corner of the content view. The
        // user invoked this from a menu, so we don't have a precise
        // anchor — this is what Finder does too.
        let anchor = NSRect(x: 0, y: contentView.bounds.height - 30,
                            width: 1, height: 1)
        picker.show(relativeTo: anchor,
                    of: contentView,
                    preferredEdge: .minY)
    }
}
