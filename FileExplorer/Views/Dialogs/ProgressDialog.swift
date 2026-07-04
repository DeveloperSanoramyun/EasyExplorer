//
//  ProgressDialog.swift
//  FileExplorer
//
//  Shown as a sheet while a long-running copy/move is in flight.
//  Mirrors the Windows Explorer transfer dialog: current file name,
//  X of Y, indeterminate spinner overlay during slow file-system stalls.
//

import SwiftUI

struct ProgressDialog: View {
    @ObservedObject var progress: FileOperationProgress
    var titleOverride: String? = nil
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: progress.errorMessage == nil ? "doc.on.doc" : "exclamationmark.triangle")
                    .feFont(size: 22)
                    .foregroundStyle(.tint)
                Text(titleOverride ?? (progress.isDone ? "Done" : "Copying…"))
                    .font(.headline)
                Spacer()
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)

            HStack {
                Text(progress.isDone
                     ? (progress.errorMessage == nil ? "Completed." : "Finished with errors.")
                     : progress.currentFileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(progress.processed) / \(progress.total)")
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Rate + ETA — only appears once the transfer has been
            // running long enough to compute a stable estimate, so a
            // 3-file copy doesn't flash misleading numbers.
            if !progress.isDone,
               let rate = progress.itemsPerSecond,
               let eta = progress.etaSeconds {
                HStack {
                    Text(String(format: "%.1f items/sec", rate))
                    Spacer()
                    Text("ETA \(formattedETA(eta))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }

            if let err = progress.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                if progress.isDone {
                    Button("Close", action: onDone)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { progress.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func formattedETA(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) sec"
        } else if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
    }
}
