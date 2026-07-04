//
//  BatchRenameDialog.swift
//  FileExplorer
//
//  Multi-file rename. Three operation modes:
//   • Find / Replace — literal or regex
//   • Add Prefix / Suffix
//   • Sequence — base name + counter (e.g. `Photo 001.png`)
//
//  A live preview list shows old → new for every selected item so the
//  user can verify before clicking Apply.
//

import SwiftUI

struct BatchRenameDialog: View {
    let urls: [URL]
    var onApply: ([URL: String]) -> Void  // {originalURL: newName}
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .findReplace
    @State private var find: String = ""
    @State private var replace: String = ""
    @State private var regex: Bool = false
    @State private var caseInsensitive: Bool = true
    @State private var prefix: String = ""
    @State private var suffix: String = ""
    @State private var baseName: String = "Item"
    @State private var startNumber: Int = 1
    @State private var pad: Int = 3
    @State private var preserveExtension: Bool = true

    /// Snapshot of names already on disk in each target directory.
    /// Computed once when the sheet appears, then reused for every
    /// previewPair recomputation — without this, every keystroke
    /// triggered N×selection `FileManager.fileExists` syscalls because
    /// SwiftUI re-evaluates the entire body on each character.
    @State private var existingNamesByParent: [String: Set<String>] = [:]
    /// Original last-path-components keyed by URL — needed to exempt
    /// self-name "conflicts" when a file's previewed new name is its
    /// own current name.
    @State private var originalNamesByURL: [URL: String] = [:]

    enum Mode: String, CaseIterable, Identifiable {
        case findReplace = "Find / Replace"
        case prefixSuffix = "Add Prefix / Suffix"
        case sequence = "Sequence"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modePicker
                    Divider()
                    optionsForm
                    Divider()
                    previewList
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .onAppear { primeNameCaches() }
    }

    /// Build the per-parent existing-name cache once so previewPairs
    /// can answer disk-conflict questions with O(1) set lookups
    /// instead of per-cell filesystem syscalls on every keystroke.
    private func primeNameCaches() {
        var existing: [String: Set<String>] = [:]
        var originals: [URL: String] = [:]
        let fm = FileManager.default
        for url in urls {
            let parent = url.deletingLastPathComponent().path
            originals[url] = url.lastPathComponent
            if existing[parent] == nil {
                let kids = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
                existing[parent] = Set(kids)
            }
        }
        existingNamesByParent = existing
        originalNamesByURL = originals
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "textformat.abc")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rename \(urls.count) Items").font(.title3.bold())
                Text("Preview updates as you type. Conflicts are highlighted in red.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases) { m in
                Text(m.rawValue).tag(m)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Options form (depends on mode)

    @ViewBuilder
    private var optionsForm: some View {
        switch mode {
        case .findReplace:
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("Find") {
                    TextField("Text to find", text: $find).textFieldStyle(.roundedBorder)
                }
                LabeledField("Replace with") {
                    TextField("Replacement text (empty = remove)", text: $replace).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 16) {
                    Toggle("Regex", isOn: $regex)
                    Toggle("Case-insensitive", isOn: $caseInsensitive)
                    Toggle("Preserve extension", isOn: $preserveExtension)
                }
            }
        case .prefixSuffix:
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("Prefix") {
                    TextField("e.g. IMG_", text: $prefix).textFieldStyle(.roundedBorder)
                }
                LabeledField("Suffix") {
                    TextField("e.g. _backup", text: $suffix).textFieldStyle(.roundedBorder)
                }
                Toggle("Insert before extension", isOn: $preserveExtension)
                    .help("Suffix is inserted before the extension. Disable to append after.")
            }
        case .sequence:
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("Base name") {
                    TextField("e.g. Photo", text: $baseName).textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 16) {
                    LabeledField("Start at") {
                        Stepper(value: $startNumber, in: 0...100000) {
                            Text("\(startNumber)").monospacedDigit().frame(width: 50)
                        }
                    }
                    LabeledField("Pad digits") {
                        Stepper(value: $pad, in: 1...8) {
                            Text("\(pad)").monospacedDigit().frame(width: 30)
                        }
                    }
                }
                Toggle("Keep original extension", isOn: $preserveExtension)
            }
        }
    }

    // MARK: - Preview list

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(previewPairs.enumerated()), id: \.offset) { _, pair in
                        previewRow(pair)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 180)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func previewRow(_ pair: PreviewPair) -> some View {
        HStack(spacing: 4) {
            Text(pair.oldName)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 240, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(pair.newName)
                .font(.caption.monospaced())
                .foregroundStyle(pair.hasConflict ? .red : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(conflictCount) conflict\(conflictCount == 1 ? "" : "s") detected")
                .font(.caption)
                .foregroundStyle(conflictCount > 0 ? .red : .secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { applyAndDismiss() }
                .keyboardShortcut(.defaultAction)
                .disabled(conflictCount > 0 || previewPairs.allSatisfy { $0.oldName == $0.newName })
        }
        .padding(12)
    }

    // MARK: - Compute previews

    private struct PreviewPair {
        let url: URL
        let oldName: String
        let newName: String
        let hasConflict: Bool
    }

    private var previewPairs: [PreviewPair] {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var seenInBatch: [String: Set<String>] = [:]   // parent → names assigned this round
        var pairs: [PreviewPair] = []
        var counter = startNumber
        for url in sorted {
            let old = url.lastPathComponent
            let next = computeNewName(for: url, counter: &counter)
            let parent = url.deletingLastPathComponent().path
            // Batch conflict: two items renamed to the same name in the
            // same parent folder.
            var batchNames = seenInBatch[parent] ?? []
            let conflictsWithBatch = !batchNames.insert(next).inserted
            seenInBatch[parent] = batchNames
            // Disk conflict: an unrelated existing file already has
            // that name — but a file mapping to its OWN current name
            // doesn't count (we'll just skip the rename in apply).
            let existing = existingNamesByParent[parent] ?? []
            let originalSelf = originalNamesByURL[url]
            let conflictsWithDisk = existing.contains(next) && next != originalSelf
            pairs.append(PreviewPair(
                url: url, oldName: old, newName: next,
                hasConflict: conflictsWithBatch || conflictsWithDisk
            ))
        }
        return pairs
    }

    private var conflictCount: Int { previewPairs.filter(\.hasConflict).count }

    private func computeNewName(for url: URL, counter: inout Int) -> String {
        let full = url.lastPathComponent
        let ext = (full as NSString).pathExtension
        let stem = (full as NSString).deletingPathExtension
        switch mode {
        case .findReplace:
            let target = preserveExtension ? stem : full
            let replaced = applyFindReplace(to: target)
            return preserveExtension && !ext.isEmpty ? "\(replaced).\(ext)" : replaced
        case .prefixSuffix:
            if preserveExtension && !ext.isEmpty {
                return "\(prefix)\(stem)\(suffix).\(ext)"
            } else {
                return "\(prefix)\(full)\(suffix)"
            }
        case .sequence:
            let n = String(format: "%0\(pad)d", counter)
            counter += 1
            if preserveExtension && !ext.isEmpty {
                return "\(baseName) \(n).\(ext)"
            } else {
                return "\(baseName) \(n)"
            }
        }
    }

    private func applyFindReplace(to text: String) -> String {
        guard !find.isEmpty else { return text }
        if regex {
            let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: find, options: options) else {
                return text
            }
            let range = NSRange(text.startIndex..., in: text)
            return re.stringByReplacingMatches(
                in: text, options: [], range: range, withTemplate: replace
            )
        } else {
            let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
            return text.replacingOccurrences(of: find, with: replace, options: options)
        }
    }

    // MARK: - Apply

    private func applyAndDismiss() {
        var map: [URL: String] = [:]
        for pair in previewPairs where pair.oldName != pair.newName {
            map[pair.url] = pair.newName
        }
        onApply(map)
        dismiss()
    }
}

// MARK: - LabeledField helper

private struct LabeledField<Content: View>: View {
    let label: String
    let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
            Spacer()
        }
    }
}
