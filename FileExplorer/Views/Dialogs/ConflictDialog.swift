//
//  ConflictDialog.swift
//  FileExplorer
//
//  Shown when a copy/move target already exists. Lets the user choose
//  Skip / Replace / Keep both, optionally "apply to all" for the rest
//  of the batch — same shape as Windows Explorer's collision dialog.
//

import SwiftUI

struct ConflictDialog: View {
    let source: URL
    let destination: URL
    /// Caller-supplied callback. Receives (decision, applyToAll).
    let onResolve: (ConflictDecision, Bool) -> Void

    @State private var applyToAll: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .feFont(size: 26)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("An item named \u{201C}\(source.lastPathComponent)\u{201D} already exists.")
                        .font(.headline)
                    Text("Choose how to handle the conflict.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Source vs destination quick comparison
            HStack(alignment: .top, spacing: 12) {
                fileBox(title: "Source", url: source)
                fileBox(title: "Destination", url: destination)
            }

            Toggle("Apply this answer to all remaining conflicts", isOn: $applyToAll)
                .font(.callout)

            HStack {
                Button("Cancel All") { onResolve(.cancel, false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { onResolve(.skip, applyToAll) }
                Button("Keep Both") { onResolve(.keepBoth, applyToAll) }
                Button("Replace") { onResolve(.replace, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder
    private func fileBox(title: String, url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detailLine(values: values))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailLine(values: URLResourceValues?) -> String {
        var parts: [String] = []
        if let bytes = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if let mod = values?.contentModificationDate {
            parts.append(FileFormatters.short(mod))
        }
        return parts.joined(separator: " · ")
    }
}
