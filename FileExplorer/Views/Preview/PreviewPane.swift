//
//  PreviewPane.swift
//  FileExplorer
//
//  Right-hand preview using QuickLook's QLPreviewView, which renders
//  images / PDFs / text / video / audio / Office docs / many more.
//  When the selection is a folder, we show summary stats instead.
//

import SwiftUI
import AppKit
import Quartz   // for QLPreviewView

struct PreviewPane: View {
    @ObservedObject var tab: TabViewModel
    @State private var folderStats: (folders: Int, files: Int, bytes: Int64)? = nil
    @State private var folderStatsURL: URL? = nil
    @State private var isCalculatingBytes: Bool = false
    /// Debounced single-selection URL that actually drives the heavy
    /// QuickLook view. It LAGS the live selection so scrubbing through
    /// many files (arrow-key autorepeat / fast clicks) doesn't spin up —
    /// and leak — a QuickLook renderer per file. QLPreviewView is
    /// WebKit-backed for many types and accumulates memory if hammered,
    /// eventually OOM-aborting the app.
    @State private var previewURL: URL?

    /// The single selected item, or nil when the selection isn't exactly
    /// one item. Drives the debounce.
    private var selectedSingle: URL? {
        tab.selectedURLs.count == 1 ? tab.selectedURLs.first : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(.background)
        // Debounce: commit the selection to the preview only after it
        // settles. `.task(id:)` cancels the pending commit whenever the
        // selection changes again, so fast scrubbing never renders an
        // intermediate file. Clearing (nil) is immediate.
        .task(id: selectedSingle) {
            let target = selectedSingle
            if target != nil {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            previewURL = target
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "eye")
                .foregroundStyle(.secondary)
            Text("Preview")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        // Multi-selection reads the LIVE count (no debounce needed — it's
        // a cheap text view). Single-file preview reads the DEBOUNCED
        // `previewURL` so the QuickLook renderer only loads once the user
        // stops scrubbing.
        if tab.selectedURLs.count > 1 {
            ContentUnavailableView(
                "\(tab.selectedURLs.count) items selected",
                systemImage: "square.stack.3d.up",
                description: Text("Select a single item to preview.")
            )
        } else if let url = previewURL {
            if FileSystemService.isReadableDirectory(url) {
                folderSummary(for: url)
            } else {
                QuickLookView(url: url)
                    // Fresh QLPreviewView per file: when the URL changes
                    // SwiftUI dismantles the old view (→ `close()` frees
                    // its renderer) instead of swapping `previewItem` in
                    // place, which leaked the WebKit-backed preview.
                    .id(url)
                    .padding(8)
            }
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "eye.slash",
                description: Text("Click an item to preview its contents.")
            )
        }
    }

    @ViewBuilder
    private func folderSummary(for url: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .feFont(size: 56)
                .foregroundStyle(.tint)
            Text(url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            // The actual counts arrive asynchronously — listing a deep
            // folder on the main thread used to stutter the preview
            // pane when the user clicked through a tree quickly.
            if folderStatsURL == url, let stats = folderStats {
                VStack(spacing: 4) {
                    Text("\(stats.folders) folder\(stats.folders == 1 ? "" : "s")")
                    Text("\(stats.files) file\(stats.files == 1 ? "" : "s")")
                    sizeRow(for: url, bytes: stats.bytes)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            await loadFolderStats(for: url)
        }
    }

    /// Three states:
    ///   1. We've already paid the recursive walk → show the total.
    ///   2. Walk in flight → spinner + "Calculating…".
    ///   3. Neither → a "Calculate Size" button that arms the walk.
    @ViewBuilder
    private func sizeRow(for url: URL, bytes: Int64) -> some View {
        if let cached = FolderSizeService.shared.cachedSize(of: url) {
            Text(ByteCountFormatter.string(fromByteCount: cached, countStyle: .file))
                .font(.callout.bold())
                .foregroundStyle(.primary)
        } else if isCalculatingBytes {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Calculating…").font(.caption)
            }
            .foregroundStyle(.tertiary)
        } else {
            Button("Calculate Size") {
                Task {
                    isCalculatingBytes = true
                    await FolderSizeService.shared.calculate(url)
                    isCalculatingBytes = false
                }
            }
            .controlSize(.small)
        }
    }

    private func loadFolderStats(for url: URL) async {
        let stats = await Task.detached(priority: .userInitiated) {
            let contents = (try? FileSystemService.listDirectory(at: url, includeHidden: false)) ?? []
            let folders = contents.filter { $0.isDirectory && !$0.isPackage }.count
            // Shallow byte total — sum of immediate-child file sizes.
            // Recursive total is opt-in via "Calculate Size" because a
            // deep tree would re-stat thousands of files for every
            // preview-pane click.
            let bytes = contents
                .filter { !($0.isDirectory && !$0.isPackage) }
                .compactMap { $0.size }
                .reduce(Int64(0), +)
            return (folders: folders, files: contents.count - folders, bytes: bytes)
        }.value
        if !Task.isCancelled {
            folderStats = stats
            folderStatsURL = url
        }
    }
}

// MARK: - QLPreviewView NSViewRepresentable

private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // The view is recreated per-URL via `.id(url)`, so this only
        // fires for same-URL parent re-renders — guard so we don't
        // needlessly reload the (heavy) preview.
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // Force QuickLook to tear the (often WebKit-backed) renderer down
        // NOW rather than whenever ARC / the window eventually releases
        // it. Without this, rapidly previewing many files piles up
        // out-of-process preview extensions until the app is OOM-aborted.
        view.close()
    }
}
