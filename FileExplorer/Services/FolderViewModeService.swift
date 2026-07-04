//
//  FolderViewModeService.swift
//  FileExplorer
//
//  Per-folder view-mode persistence. The global @AppStorage value
//  remains the default for folders the user has never customised; this
//  service adds an override layer keyed by absolute path so each folder
//  can remember its last-used Icons / List / Details mode independently.
//
//  Storage shape: a single JSON-encoded `[String: String]` blob in
//  UserDefaults — simpler than minting a key per folder and survives
//  the case where the user has thousands of folder entries (UserDefaults
//  is fine with one big value, miserable with thousands of small ones).
//

import Foundation
import Combine

@MainActor
final class FolderViewModeService: ObservableObject {

    static let shared = FolderViewModeService()

    @Published private var modes: [String: String] = [:]

    private let storageKey = "fe.folderViewModes"

    private init() {
        load()
    }

    // MARK: - Public API

    /// Returns the saved mode for `url`, or nil if the user hasn't set
    /// one — the caller should fall back to the global default in that
    /// case.
    func mode(for url: URL) -> FileViewMode? {
        guard let raw = modes[url.path] else { return nil }
        return FileViewMode(rawValue: raw)
    }

    /// Persist `mode` as `url`'s preference. Future visits to that path
    /// will get this mode regardless of what the global default is.
    func setMode(_ mode: FileViewMode, for url: URL) {
        modes[url.path] = mode.rawValue
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        modes = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(modes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
