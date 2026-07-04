//
//  PermissionGuide.swift
//  FileExplorer
//
//  Helpers for routing the user to macOS's privacy panels when TCC
//  blocks a file operation. macOS doesn't offer a programmatic way to
//  request Full Disk Access — apps can only open the right Settings
//  pane and ask the user to flip a switch. These URLs are the
//  documented anchors for each privacy category.
//

import Foundation
import AppKit

enum PermissionGuide {

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    /// Once the user adds FileExplorer there and re-launches, the
    /// listing of ~/Library / /System / .Trash etc. starts working.
    static func openFullDiskAccessSettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    /// Files & Folders pane (Desktop / Documents / Downloads). macOS
    /// usually prompts on first access; this is a manual back-door for
    /// when the user previously denied the prompt.
    static func openFilesAndFoldersSettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    /// Automation (Apple Events). Trash actions go via Finder
    /// scripting, which is gated by this pane.
    static func openAutomationSettings() {
        openSettings(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func openSettings(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
