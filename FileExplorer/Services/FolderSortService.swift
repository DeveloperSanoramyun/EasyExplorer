//
//  FolderSortService.swift
//  FileExplorer
//
//  Per-folder sort preference. Mirrors FolderViewModeService — the
//  global `fe.sortKey` / `fe.sortAscending` keys still hold a default
//  for unseen folders, but anything the user explicitly sorted gets
//  remembered keyed by path.
//
//  Without this, switching between a Downloads folder (date-desc)
//  and a Documents folder (name-asc) re-sorted both every time the
//  user opened them — annoying since file managers traditionally
//  remember per-folder.
//

import Foundation
import Combine

@MainActor
final class FolderSortService: ObservableObject {

    static let shared = FolderSortService()

    /// On-disk shape: `{ "/abs/path": { "key": "name", "asc": true } }`
    /// stored as one JSON blob so we don't pollute UserDefaults with
    /// thousands of per-folder keys.
    struct Preference: Codable, Equatable {
        let key: String   // FileItem.SortKey.rawValue
        let asc: Bool
    }

    @Published private var prefs: [String: Preference] = [:]

    private let storageKey = "fe.folderSortPrefs"

    private init() {
        load()
    }

    // MARK: - Public API

    /// Returns `(key, ascending)` for `url`, or nil when the user
    /// hasn't explicitly sorted that folder. Callers fall back to the
    /// global default in that case.
    func preference(for url: URL) -> (key: FileItem.SortKey, ascending: Bool)? {
        guard let p = prefs[url.path],
              let key = FileItem.SortKey(rawValue: p.key) else { return nil }
        return (key, p.asc)
    }

    func setPreference(_ key: FileItem.SortKey, ascending: Bool, for url: URL) {
        prefs[url.path] = Preference(key: key.rawValue, asc: ascending)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Preference].self, from: data)
        else { return }
        prefs = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
