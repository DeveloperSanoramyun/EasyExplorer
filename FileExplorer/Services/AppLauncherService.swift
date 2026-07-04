//
//  AppLauncherService.swift
//  FileExplorer
//
//  "Open With…" — list every application macOS thinks can handle a
//  given file, and open it with whichever the user picks. Powered by
//  `NSWorkspace.urlsForApplications(toOpen:)` (replacement for the old
//  LaunchServices C API).
//
//  We deliberately keep the list short — the system can return dozens
//  of handlers for common UTIs like text/plain — but show all when
//  asked. The default app is highlighted at the top.
//

import Foundation
import AppKit

@MainActor
enum AppLauncherService {

    struct AppEntry: Identifiable, Hashable {
        let id: URL                  // path to the .app bundle
        let url: URL                 // same — kept for clarity
        let name: String             // localized application name
        let icon: NSImage
        let isDefault: Bool          // true if it's the registered default
    }

    /// Returns every application registered to open `url`, with the
    /// system-default handler marked. Falls back to an empty list when
    /// LaunchServices has no candidates — the menu should hide itself
    /// in that case.
    ///
    /// Duplicate-handling: LaunchServices returns one URL per registered
    /// copy of an app, so during iterative development a single bundle
    /// identifier (e.g. com.myungsan.fileexplorer) can show up several
    /// times — once for /Applications, once per DerivedData build, etc.
    /// We collapse those down by `CFBundleIdentifier`, preferring the
    /// canonical install location and treating Xcode build outputs as
    /// the least desirable candidate.
    static func applications(handlerFor url: URL) -> [AppEntry] {
        let ws = NSWorkspace.shared
        let candidates = ws.urlsForApplications(toOpen: url)
        guard !candidates.isEmpty else { return [] }

        let defaultURL = ws.urlForApplication(toOpen: url)?.resolvingSymlinksInPath()

        // Group by bundle id (fallback to the executable name when the
        // bundle has no identifier — rare but happens for command-line
        // wrappers). Within each group, pick the highest-ranked path.
        var groups: [String: [URL]] = [:]
        for appURL in candidates {
            let bundle = Bundle(url: appURL)
            let key = (bundle?.bundleIdentifier?.lowercased())
                ?? appURL.deletingPathExtension().lastPathComponent.lowercased()
            groups[key, default: []].append(appURL)
        }

        let deduped: [URL] = groups.values.compactMap { urls in
            urls.min { preferenceRank(for: $0) < preferenceRank(for: $1) }
        }

        return deduped.map { appURL -> AppEntry in
            let bundle = Bundle(url: appURL)
            let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            // Compare resolved paths so a symlink-y default URL still
            // matches its real on-disk twin.
            let isDefault = appURL.resolvingSymlinksInPath() == defaultURL
            return AppEntry(
                id: appURL,
                url: appURL,
                name: displayName,
                icon: ws.icon(forFile: appURL.path),
                isDefault: isDefault
            )
        }
        // Default first, then alphabetical — Finder does the same.
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Lower rank = preferred. /Applications wins, then ~/Applications,
    /// then anything else, with Xcode DerivedData explicitly demoted so
    /// stale build artifacts don't shadow the real install.
    private static func preferenceRank(for url: URL) -> Int {
        let path = url.path
        if path.contains("/DerivedData/")          { return 100 }
        if path.contains("/Library/Caches/")       { return 90 }
        if path.hasPrefix("/Applications/")        { return 0 }
        if path.hasPrefix("/System/Applications/") { return 10 }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Applications/") { return 20 }
        return 50
    }

    /// Open each URL with the picked application. Uses the modern
    /// configuration-based API so we can pass `activates = true` and
    /// avoid the deprecated openFile:withApplication: call.
    static func open(_ urls: [URL], with app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: app,
            configuration: config
        ) { _, _ in }
    }

    /// "Other Application…" — pops an NSOpenPanel rooted at
    /// /Applications so the user can hand-pick any installed app. This
    /// is the fallback when LaunchServices doesn't know about a
    /// particular file type, and it always appears so the Open With
    /// submenu has at least one entry.
    static func chooseApplication(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Pick an application to open \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") with."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let appURL = panel.url {
            open(urls, with: appURL)
        }
    }
}
