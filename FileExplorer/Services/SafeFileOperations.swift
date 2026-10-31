import Foundation
import Darwin

/// Shared by worker code and the main-actor progress model.
final class OperationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var copied: Int64 = 0
    private var planned: Int64 = 0
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled || Task.isCancelled { throw CancellationError() } }
    func add(_ bytes: Int64) { lock.lock(); copied += max(0, bytes); lock.unlock() }
    func plan(_ bytes: Int64) { lock.lock(); planned += max(0, bytes); lock.unlock() }
    var bytes: (done: Int64, total: Int64) {
        lock.lock(); defer { lock.unlock() }; return (copied, planned)
    }
}

/// Serializes long operations across tabs/windows. Cancellation remains responsive
/// while waiting. Short filesystem commits and history share a separate lock.
actor OperationQueue {
    static let shared = OperationQueue()
    private var busy = false
    private var waiting: [UUID] = []
    func acquire(_ control: OperationControl) async throws {
        let id = UUID(); waiting.append(id)
        do {
            while busy || waiting.first != id {
                try control.check()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try control.check()
            waiting.removeFirst(); busy = true
        } catch { waiting.removeAll { $0 == id }; throw error }
    }
    func release() { busy = false }
}

enum MutationLock {
    static let lock = NSRecursiveLock()
    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

struct FileIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
}

struct FileSnapshot: Equatable {
    let entries: [String: FileIdentity]
    init(_ root: URL, control: OperationControl = OperationControl()) throws {
        var entries = ["": try FileIdentity(root)]
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true, values.isSymbolicLink != true {
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                errorHandler: { _, error in failure = error; return false }) else { throw SafeFiles.error("Cannot verify folder contents: \(root.path)") }
            for case let child as URL in iterator {
                try control.check()
                entries[String(child.path.dropFirst(root.path.count))] = try FileIdentity(child)
            }
            if let failure { throw failure }
        }
        self.entries = entries
    }
}

enum SafeFiles {
    static func error(_ message: String) -> NSError {
        NSError(domain: "FileExplorer", code: 40, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func exists(_ url: URL) -> Bool { (try? FileIdentity(url)) != nil }
    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        let a = a.resolvingSymlinksInPath().standardizedFileURL
        let b = b.resolvingSymlinksInPath().standardizedFileURL
        if a == b { return true }
        guard let x = try? FileIdentity(a), let y = try? FileIdentity(b) else { return false }
        return x.device == y.device && x.inode == y.inode
    }
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.resolvingSymlinksInPath().standardizedFileURL.path
        let p = parent.resolvingSymlinksInPath().standardizedFileURL.path
        return c == p || c.hasPrefix(p == "/" ? "/" : p + "/")
    }
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), name.utf8.count <= 255 else {
            throw error("Invalid file name: \(name)")
        }
    }
    static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while exists(candidate) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + " \(n)" + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
            n += 1
        }
        return candidate
    }
    static func privateDirectory(in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(".FileExplorer-Recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        RecoveryStore.register(url)
        return url
    }
    /// A same-volume rename first makes retirement recoverable even on
    /// volumes where system Trash is unavailable. Never recursively delete.
    static func retire(_ url: URL) throws -> URL {
        let fm = FileManager.default
        let workspace = try privateDirectory(in: url.deletingLastPathComponent())
        let held = workspace.appendingPathComponent(url.lastPathComponent)
        do {
            try JSONSerialization.data(withJSONObject: ["original": url.path, "held": held.path])
                .write(to: workspace.appendingPathComponent("recovery.json"), options: .atomic)
            try fm.moveItem(at: url, to: held)
        } catch { try? fm.removeItem(at: workspace); throw error }
        // The private recovery directory is deliberately retained. History
        // needs a stable URL even when the system Trash is inaccessible.
        return held
    }
    static func logicalSize(_ url: URL, control: OperationControl) throws -> Int64 {
        try control.check()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let v = try url.resourceValues(forKeys: keys)
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true { return Int64(v.fileSize ?? 0) }
        var sum: Int64 = 0
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, error in failure = error; return false }) else { throw error("Cannot enumerate \(url.path)") }
        for case let child as URL in iterator {
            try control.check()
            let values = try child.resourceValues(forKeys: keys)
            if values.isRegularFile == true, values.isSymbolicLink != true { sum += Int64(values.fileSize ?? 0) }
        }
        if let failure { throw failure }
        return sum
    }
    private final class CopyContext {
        let control: OperationControl
        var lastPath = ""
        var lastBytes: Int64 = 0
        init(_ control: OperationControl) { self.control = control }
    }
    static func copy(_ source: URL, to destination: URL, control: OperationControl) throws {
        try control.check()
        guard let state = copyfile_state_alloc() else { throw error("Cannot allocate copy state.") }
        defer { copyfile_state_free(state) }
        let context = CopyContext(control)
        let callback: copyfile_callback_t = { what, stage, state, src, _, raw in
            guard let raw else { return Int32(COPYFILE_QUIT) }
            let context = Unmanaged<CopyContext>.fromOpaque(raw).takeUnretainedValue()
            if context.control.isCancelled || stage == COPYFILE_ERR { return Int32(COPYFILE_QUIT) }
            if what == COPYFILE_COPY_DATA {
                let path = src.map { String(cString: $0) } ?? ""
                if path != context.lastPath { context.lastPath = path; context.lastBytes = 0 }
                var bytes: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes)
                context.control.add(max(0, bytes - context.lastBytes)); context.lastBytes = bytes
            }
            return Int32(COPYFILE_CONTINUE)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        if copyfile(source.path, destination.path, state, flags) != 0 {
            try control.check()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try control.check()
    }

    /// The previous target is moved aside only AFTER staging succeeds.
    /// A failed commit restores it; a failed restore leaves a recovery manifest.
    static func install(_ staged: URL, at destination: URL, replacing expected: FileIdentity?, workspace: URL) throws -> URL? {
        try MutationLock.withLock {
            let current = try? FileIdentity(destination)
            guard current == expected else { throw error("Destination changed during the operation: \(destination.path)") }
            let fm = FileManager.default
            let backup = workspace.appendingPathComponent("previous")
            if expected != nil {
                let manifest = ["destination": destination.path, "backup": backup.path]
                try JSONSerialization.data(withJSONObject: manifest).write(to: workspace.appendingPathComponent("recovery.json"), options: .atomic)
                try fm.moveItem(at: destination, to: backup)
            }
            do {
                try fm.moveItem(at: staged, to: destination)
            } catch {
                if expected != nil {
                    do { try fm.moveItem(at: backup, to: destination) }
                    catch { throw self.error("Recovery required. Your original is preserved at \(backup.path). \(error.localizedDescription)") }
                }
                throw error
            }
            return expected == nil ? nil : backup
        }
    }
}

/// Drains both pipes while the child runs. Buffers are capped; surplus output is
/// discarded instead of blocking the child or growing memory without bound.
enum ProcessRunner {
    private final class Buffer: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk.prefix(max(0, 1_048_576 - data.count)))
        }
        func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    struct Result { let status: Int32; let output: Data; let error: String }
    static func run(_ executable: String, _ arguments: [String], control: OperationControl = OperationControl(), timeout: TimeInterval = 3600) throws -> Result {
        try control.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let out = Pipe(), err = Pipe(), output = Buffer(), errors = Buffer()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let group = DispatchGroup()
        for (pipe, buffer) in [(out, output), (err, errors)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var interrupted = false
        while process.isRunning {
            if control.isCancelled || Task.isCancelled || Date() > deadline {
                interrupted = true; process.terminate()
                let stop = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stop { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        if interrupted {
            try control.check()
            throw SafeFiles.error("Operation timed out: \((executable as NSString).lastPathComponent)")
        }
        return Result(status: process.terminationStatus, output: output.snapshot(),
                      error: String(data: errors.snapshot(), encoding: .utf8) ?? "Tool failed.")
    }
}

/// Each record tracks identity and phase, allowing a partially completed Undo
/// to be retried without touching already-reversed items or unrelated files.
final class TransferRecord {
    let source: URL
    let destination: URL
    let move: Bool
    var backup: URL?
    var heldCopy: URL?
    var identity: FileIdentity
    var snapshot: FileSnapshot
    var backupSnapshot: FileSnapshot?
    var backupIdentity: FileIdentity?
    var isApplied = true
    init(source: URL, destination: URL, move: Bool, backup: URL?) throws {
        self.source = source; self.destination = destination; self.move = move; self.backup = backup
        identity = try FileIdentity(destination)
        snapshot = try FileSnapshot(destination)
        backupSnapshot = try backup.map { try FileSnapshot($0) }
        backupIdentity = try backup.map { try FileIdentity($0) }
    }
    func undo() throws {
        guard isApplied else { return }
        try MutationLock.withLock {
            guard try FileSnapshot(destination) == snapshot else { throw SafeFiles.error("Item changed since transfer: \(destination.path)") }
            if move && SafeFiles.exists(source) { throw SafeFiles.error("Original location is occupied: \(source.path)") }
            if let backup, try FileSnapshot(backup) != backupSnapshot { throw SafeFiles.error("Recovery item changed: \(backup.path)") }
            let fm = FileManager.default
            let held: URL
            if move {
                try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: destination, to: source); held = source
            } else {
                held = try SafeFiles.retire(destination)
            }
            do {
                if let backup { try fm.moveItem(at: backup, to: destination) }
            } catch {
                try fm.moveItem(at: held, to: destination)
                throw error
            }
            heldCopy = held
            identity = try FileIdentity(held)
            snapshot = try FileSnapshot(held)
            if backup != nil { backupIdentity = try FileIdentity(destination); backupSnapshot = try FileSnapshot(destination) }
            isApplied = false
        }
    }
    func redo() throws {
        guard !isApplied, let held = heldCopy else { return }
        try MutationLock.withLock {
            guard try FileSnapshot(held) == snapshot else { throw SafeFiles.error("Undo item changed: \(held.path)") }
            let expected = backup != nil ? backupIdentity : nil
            guard (try? FileIdentity(destination)) == expected else { throw SafeFiles.error("Destination is occupied or changed: \(destination.path)") }
            if backup != nil, try FileSnapshot(destination) != backupSnapshot { throw SafeFiles.error("Previous target changed since Undo.") }
            let fm = FileManager.default
            if let backup { try fm.moveItem(at: destination, to: backup) }
            do { try fm.moveItem(at: held, to: destination) }
            catch {
                if let backup { try fm.moveItem(at: backup, to: destination) }
                throw error
            }
            identity = try FileIdentity(destination)
            snapshot = try FileSnapshot(destination)
            isApplied = true
        }
    }
}

final class RenameHistory {
    private var current: [(url: URL, alternate: URL, identity: FileIdentity)]
    init(_ pairs: [(URL, URL)]) throws {
        current = try pairs.map { (url: $0.1, alternate: $0.0, identity: try FileIdentity($0.1)) }
    }
    func toggle(control: OperationControl = OperationControl()) throws {
        let plan = try current.map { entry -> (URL, URL) in
            guard try FileIdentity(entry.url) == entry.identity else { throw SafeFiles.error("Renamed item changed: \(entry.url.path)") }
            return (entry.url, entry.alternate)
        }
        try BatchRenamer.apply(plan, control: control)
        current = try current.map { (url: $0.alternate, alternate: $0.url, identity: try FileIdentity($0.alternate)) }
    }
}

enum BatchRenamer {
    static func apply(_ plan: [(URL, URL)], control: OperationControl) throws {
        try MutationLock.withLock {
            let fm = FileManager.default
            let originals = Set(plan.map { $0.0.standardizedFileURL })
            var targets: Set<URL> = []
            for (source, target) in plan {
                try SafeFiles.validateName(target.lastPathComponent)
                guard source.deletingLastPathComponent() == target.deletingLastPathComponent() else { throw SafeFiles.error("Rename must stay in the original folder.") }
                guard targets.insert(target.standardizedFileURL).inserted else { throw SafeFiles.error("Duplicate rename target: \(target.path)") }
                if SafeFiles.exists(target), !originals.contains(target.standardizedFileURL), !SafeFiles.sameItem(source, target) {
                    throw SafeFiles.error("Rename target already exists: \(target.path)")
                }
            }
            var entries: [(original: URL, temporary: URL, final: URL, installed: Bool)] = []
            do {
                for (source, target) in plan {
                    try control.check()
                    let temporary = source.deletingLastPathComponent().appendingPathComponent(".__fe_rename_" + UUID().uuidString)
                    try fm.moveItem(at: source, to: temporary)
                    entries.append((source, temporary, target, false))
                }
                for i in entries.indices {
                    try control.check()
                    try fm.moveItem(at: entries[i].temporary, to: entries[i].final)
                    entries[i].installed = true
                }
            } catch {
                let originalError = error
                var failures: [String] = []
                // Vacate all final names first, then restore originals. This
                // also rolls back swaps/cycles without name collisions.
                for i in entries.indices where entries[i].installed {
                    do { try fm.moveItem(at: entries[i].final, to: entries[i].temporary); entries[i].installed = false }
                    catch { failures.append(entries[i].final.path) }
                }
                for entry in entries where !entry.installed {
                    do { try fm.moveItem(at: entry.temporary, to: entry.original) }
                    catch { failures.append(entry.temporary.path) }
                }
                if !failures.isEmpty { throw SafeFiles.error("Rename recovery required at: " + failures.joined(separator: ", ")) }
                throw originalError
            }
        }
    }
}

final class TrashHistory {
    private struct Item {
        let original: URL
        var trash: URL
        var identity: FileIdentity
        var restored = false
    }
    private var items: [Item]
    init(_ pairs: [(original: URL, trashed: URL?)]) {
        items = pairs.compactMap { pair in
            guard let trash = pair.trashed, let identity = try? FileIdentity(trash) else { return nil }
            return Item(original: pair.original, trash: trash, identity: identity)
        }
    }
    func apply(restore: Bool) throws {
        try MutationLock.withLock {
            var failures: [String] = []
            for i in items.indices where items[i].restored != restore {
                do {
                    let item = items[i]
                    let current = restore ? item.trash : item.original
                    guard try FileIdentity(current) == item.identity else { throw SafeFiles.error("Item changed: \(current.path)") }
                    if restore {
                        guard !SafeFiles.exists(item.original) else { throw SafeFiles.error("Original location is occupied: \(item.original.path)") }
                        try FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: item.trash, to: item.original)
                    } else {
                        var result: NSURL?
                        try FileManager.default.trashItem(at: item.original, resultingItemURL: &result)
                        guard let trash = result as URL? else { throw SafeFiles.error("Cannot locate item in Trash.") }
                        items[i].trash = trash
                    }
                    items[i].identity = try FileIdentity(restore ? item.original : items[i].trash)
                    items[i].restored = restore
                } catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { throw SafeFiles.error(failures.joined(separator: "\n")) }
        }
    }
}


/// Only this app's explicitly registered temporary directories are considered.
/// Recovery payloads/old targets are never auto-deleted.
enum RecoveryStore {
    private static let key = "fe.recoveryWorkspaces"
    #if CORE_TESTS
    private static let defaults = UserDefaults(suiteName: "com.myungsan.fileexplorer.CoreTests")!
    #else
    private static let defaults = UserDefaults.standard
    #endif
    static func register(_ url: URL) {
        MutationLock.withLock {
            var paths = defaults.stringArray(forKey: key) ?? []
            if !paths.contains(url.path) { paths.append(url.path) }
            defaults.set(paths, forKey: key)
        }
    }
    static func directories() -> [URL] {
        (defaults.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.lastPathComponent.hasPrefix(".FileExplorer-Recovery-") && SafeFiles.exists($0) }
    }
    static func cleanAbandoned() {
        MutationLock.withLock {
            let fm = FileManager.default
            for url in directories() {
                let manifest = url.appendingPathComponent("recovery.json")
                if SafeFiles.exists(manifest) { continue }
                guard let values = try? url.resourceValues(forKeys: [.creationDateKey]),
                      let created = values.creationDate, Date().timeIntervalSince(created) > 86_400 else { continue }
                try? fm.removeItem(at: url)
            }
            defaults.set(directories().map(\.path), forKey: key)
        }
    }
}
