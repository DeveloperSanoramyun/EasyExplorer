//
//  ConflictDialog.swift
//  FileExplorer
//
//  Source-vs-destination comparison shown INSIDE the conflict NSAlert
//  (ConflictPrompt in FileOperationService) via an NSHostingView
//  accessory. The alert has to be an NSAlert — a SwiftUI sheet can't
//  present over the already-presented transfer-progress sheet — but a
//  bare alert only showed the file NAME, which is useless when both
//  sides are "photo.jpg". This view adds real QuickLook thumbnails plus
//  size / modification date / location so the user can tell the two
//  apart before choosing Replace / Keep Both / Skip.
//
//  (An earlier standalone `ConflictDialog` SwiftUI sheet lived here; it
//  was never presented once the NSAlert flow landed, so it's gone.)
//

import SwiftUI
import AppKit

struct ConflictComparisonView: View {
    let source: URL
    let destination: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            fileBox(title: "Source", url: source)
            fileBox(title: "Existing", url: destination)
        }
        .padding(.top, 4)
        .frame(width: 460)
    }

    @ViewBuilder
    private func fileBox(title: String, url: URL) -> some View {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                // Real QuickLook thumbnail (not the generic file-type
                // icon) so two same-named files are visually
                // distinguishable. Falls back to the plain icon when the
                // item vanished between the conflict firing and this
                // rendering.
                if let item = FileItem.from(url: url) {
                    ThumbnailIcon(item: item, sizeClass: .medium, pointSize: 28)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                }
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
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
