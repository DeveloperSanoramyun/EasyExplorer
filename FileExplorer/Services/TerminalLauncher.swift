//
//  TerminalLauncher.swift
//  FileExplorer
//
//  Open a folder in Terminal.app. Uses NSWorkspace's URL-based API so
//  Terminal opens a new window/tab with that directory as its cwd —
//  the same behaviour you get from `open -a Terminal <path>`.
//
//  We deliberately hard-code Terminal.app (not iTerm2 etc.) because
//  macOS has no system-wide "default terminal" concept; respecting an
//  alternative would require either a user setting or LaunchServices
//  inspection. Terminal.app is always present.
//

import Foundation
import AppKit

enum TerminalLauncher {

    private static let terminalAppURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Terminal.app"
    )

    /// Open `folder` in a new Terminal window. Silent on failure —
    /// Terminal.app should always be reachable, and the worst case is
    /// the user notices nothing happened.
    static func open(_ folder: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [folder],
            withApplicationAt: terminalAppURL,
            configuration: config
        ) { _, _ in }
    }
}
