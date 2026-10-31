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

@MainActor
enum BrowserActions {
    static func showRecoveryFolders() {
        let directories = RecoveryStore.directories()
        let alert = NSAlert(); alert.messageText = "Recovery Folders"
        alert.informativeText = "Previous versions and undone items are retained here. Restore using Copy/Move after checking the recorded original location. These items are never automatically deleted."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 580, height: 28))
        picker.addItems(withTitles: directories.isEmpty ? ["No recovery items"] : directories.map(\.path))
        alert.accessoryView = picker; alert.addButton(withTitle: "Show Folder"); alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn, directories.indices.contains(picker.indexOfSelectedItem) {
            NSWorkspace.shared.activateFileViewerSelecting([directories[picker.indexOfSelectedItem]])
        }
    }
    static func connectToServer() {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = "Enter an SMB or AFP server address. macOS handles sign-in and saved credentials."
        let field = NSTextField(string: "smb://")
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["smb", "afp"].contains(scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else {
            let error = NSAlert(); error.messageText = "Enter a server address such as smb://server/share without embedded credentials."; error.runModal(); return
        }
        NSWorkspace.shared.open(url)
    }
    static func createLink(_ source: URL, alias: Bool, tab: TabViewModel) {
        do {
            let name = source.lastPathComponent + (alias ? " alias" : " link")
            let target = SafeFiles.unique(source.deletingLastPathComponent().appendingPathComponent(name))
            if alias {
                let data = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: target)
            } else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source) }
            tab.reload(); tab.selectedIDs = [target]
        } catch { tab.reportOpError(error.localizedDescription) }
    }
    static func revealOriginal(_ source: URL, tab: TabViewModel) {
        do {
            let values = try source.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
            let target = values.isAliasFile == true
                ? try URL(resolvingAliasFileAt: source, options: [.withoutUI])
                : source.resolvingSymlinksInPath()
            guard SafeFiles.exists(target) else { throw SafeFiles.error("The link target is missing: \(target.path)") }
            tab.navigate(to: FileSystemService.isReadableDirectory(target) ? target : target.deletingLastPathComponent())
            if !FileSystemService.isReadableDirectory(target) { tab.selectedIDs = [target] }
        } catch { tab.reportOpError(error.localizedDescription) }
    }
    static func cloudStatus(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey]), v.isUbiquitousItem == true else { return nil }
        if v.ubiquitousItemIsDownloading == true { return "iCloud: downloading" }
        if v.ubiquitousItemIsUploading == true { return "iCloud: uploading" }
        return v.ubiquitousItemDownloadingStatus == .current ? "iCloud: available offline" : "iCloud: stored in cloud or waiting to sync"
    }
    static func cloud(_ url: URL, download: Bool, tab: TabViewModel) {
        do {
            if download { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
            else { try FileManager.default.evictUbiquitousItem(at: url) }
            tab.reload()
        } catch { tab.reportOpError(error.localizedDescription) }
    }
}
