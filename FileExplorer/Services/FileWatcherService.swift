//
//  FileWatcherService.swift
//  FileExplorer
//
//  Thin wrapper around FSEventStream. Subscribes to filesystem changes
//  in a single directory (latency 0.5s; the stream batches events) and
//  invokes a callback on the main queue when anything inside changes —
//  files added / removed / renamed / modified.
//

import Foundation
import CoreServices

// Not @MainActor so deinit (which is nonisolated) can still tear the
// stream down. The C callback already runs on the main queue because
// we set it as the dispatch queue, so observers are still main-safe.
final class FileWatcherService {

    private var stream: FSEventStreamRef?
    private var onChange: (() -> Void)?

    /// Begin watching `url`. Replaces any previous watch.
    func watch(_ url: URL, onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        // Trampoline from C callback back to Swift instance.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                watcher.onChange?()
            }
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let pathsToWatch = [url.path] as CFArray
        let latency: CFTimeInterval = 0.5     // group bursts within 500 ms

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        onChange = nil
    }

    deinit {
        // FSEventStreamRef is C; safe to release off the main actor.
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
