//
//  PropertiesDialog.swift
//  FileExplorer
//
//  "Get Info"-style sheet — General / Permissions / Details tabs,
//  matching Windows Explorer's tabbed Properties window. Permissions
//  tab exposes POSIX rwx flags as toggles plus Lock/Hidden attribute
//  switches; chmod-style precise input is reachable via the octal
//  field.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PropertiesDialog: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .general
    @State private var tags: [String] = []
    @State private var values: URLResourceValues?
    @State private var posix: PosixPermissions = .zero
    @State private var isLocked: Bool = false
    @State private var isHidden: Bool = false
    @State private var holders: [LSOFService.Holder] = []
    @State private var holdersChecked: Bool = false

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case permissions = "Permissions"
        case details = "Details"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                Group {
                    switch selectedTab {
                    case .general:     generalTab
                    case .permissions: permissionsTab
                    case .details:     detailsTab
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Divider()
            footer
        }
        .frame(width: 480, height: 540)
        .onAppear { reload() }
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                Text(typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            kvRow("Where",    url.deletingLastPathComponent().path)
            kvRow("Size",     sizeText)
            kvRow("Created",  formattedDate(values?.creationDate))
            kvRow("Modified", formattedDate(values?.contentModificationDate))
            kvRow("Type",     typeLabel)

            Divider()

            // Tags — the colour-tag palette every Mac user expects.
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(TagService.standardTags, id: \.name) { tag in
                        Button {
                            toggleTag(tag.name)
                        } label: {
                            Circle()
                                .fill(Color(nsColor: tag.color))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: tags.contains(tag.name) ? "checkmark" : "")
                                        .foregroundStyle(.white)
                                        .feFont(size: 11, weight: .bold)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(tag.name)
                    }
                }
                if !tags.isEmpty {
                    Text("Active: " + tags.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var permissionsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UNIX permissions")
                .font(.subheadline.weight(.semibold))

            // The rwx matrix — three rows (owner / group / world),
            // three columns each. Toggling a cell flips the underlying
            // POSIX bit and writes through to the file system.
            permissionGrid

            HStack(spacing: 8) {
                Text("Octal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", text: octalBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .monospaced()
                    .onSubmit { applyOctal() }
                Text("(e.g. 755, 644)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            Divider()

            Text("Finder attributes")
                .font(.subheadline.weight(.semibold))

            Toggle("Locked (can't be modified or deleted)", isOn: $isLocked)
                .onChange(of: isLocked) { _, newValue in setLocked(newValue) }
            Toggle("Hidden (dot-style invisible item)", isOn: $isHidden)
                .onChange(of: isHidden) { _, newValue in setHidden(newValue) }
        }
    }

    @ViewBuilder
    private var detailsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            kvRow("UTI",      values?.typeIdentifier ?? "—")
            kvRow("Path",     url.path)
            kvRow("Symlink",  (values?.isSymbolicLink ?? false) ? "Yes" : "No")
            kvRow("Package",  (values?.isPackage ?? false) ? "Yes" : "No")
            kvRow("Accessed", formattedDate(values?.contentAccessDate))
            kvRow("Inode",    values?.fileResourceIdentifier.map { "\($0)" } ?? "—")

            Divider()

            HStack {
                Text("In Use By")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                if !holdersChecked {
                    Button("Check") {
                        loadHolders()
                    }
                    .controlSize(.small)
                } else if holders.isEmpty {
                    Text("Nothing is holding this file open.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(holders) { h in
                            Text("\(h.command) — pid \(h.pid)")
                                .font(.caption.monospaced())
                        }
                    }
                }
                Spacer()
            }
        }
    }

    private func loadHolders() {
        holdersChecked = true
        Task.detached(priority: .userInitiated) {
            let result = LSOFService.holders(of: url)
            await MainActor.run {
                holders = result
            }
        }
    }

    // MARK: - Permissions grid

    @ViewBuilder
    private var permissionGrid: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                Text("").frame(width: 70, alignment: .trailing)
                Text("Read").font(.caption.weight(.semibold))
                Text("Write").font(.caption.weight(.semibold))
                Text("Execute").font(.caption.weight(.semibold))
            }
            GridRow {
                Text("Owner").font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                bitToggle(.ownerRead)
                bitToggle(.ownerWrite)
                bitToggle(.ownerExec)
            }
            GridRow {
                Text("Group").font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                bitToggle(.groupRead)
                bitToggle(.groupWrite)
                bitToggle(.groupExec)
            }
            GridRow {
                Text("Everyone").font(.callout).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                bitToggle(.otherRead)
                bitToggle(.otherWrite)
                bitToggle(.otherExec)
            }
        }
    }

    @ViewBuilder
    private func bitToggle(_ bit: PosixPermissions.Bit) -> some View {
        Toggle("", isOn: bitBinding(bit))
            .labelsHidden()
    }

    private func bitBinding(_ bit: PosixPermissions.Bit) -> Binding<Bool> {
        Binding(
            get: { posix.has(bit) },
            set: { newValue in
                posix.set(bit, on: newValue)
                applyPosix()
            }
        )
    }

    private var octalBinding: Binding<String> {
        Binding(
            get: { posix.octalString },
            set: { newValue in
                if let parsed = PosixPermissions(octalString: newValue) {
                    posix = parsed
                }
            }
        )
    }

    // MARK: - State writes

    private func applyPosix() {
        let mode = NSNumber(value: posix.mode)
        try? FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    private func applyOctal() {
        applyPosix()
    }

    private func setLocked(_ newValue: Bool) {
        var v = URLResourceValues()
        v.isUserImmutable = newValue
        do {
            var url = url
            try url.setResourceValues(v)
        } catch {
            NSLog("Lock toggle failed: \(error)")
        }
    }

    private func setHidden(_ newValue: Bool) {
        var v = URLResourceValues()
        v.isHidden = newValue
        do {
            var url = url
            try url.setResourceValues(v)
        } catch {
            NSLog("Hidden toggle failed: \(error)")
        }
    }

    // MARK: - Loaders

    private func reload() {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .totalFileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey,
            .contentAccessDateKey,
            .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
            .typeIdentifierKey,
            .isUserImmutableKey, .isHiddenKey,
            .fileResourceIdentifierKey
        ]
        values = try? url.resourceValues(forKeys: keys)
        tags = TagService.tagNames(of: url)
        isLocked = values?.isUserImmutable ?? false
        isHidden = values?.isHidden ?? false

        // POSIX mode — FileManager.attributesOfItem returns it as a
        // bridged NSNumber under .posixPermissions.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modeNum = attrs[.posixPermissions] as? NSNumber {
            posix = PosixPermissions(mode: modeNum.uint16Value)
        }
    }

    private func toggleTag(_ name: String) {
        TagService.toggleTag(name, on: [url])
        tags = TagService.tagNames(of: url)
    }

    // MARK: - Derived

    private var typeLabel: String {
        if values?.isDirectory == true && values?.isPackage == false { return "Folder" }
        if let utiID = values?.typeIdentifier,
           let ut = UTType(utiID),
           let description = ut.localizedDescription { return description }
        let ext = (url.lastPathComponent as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased() + " file"
    }

    private var sizeText: String {
        if values?.isDirectory == true && values?.isPackage == false {
            if let cached = FolderSizeService.shared.cachedSize(of: url) {
                return ByteCountFormatter.string(fromByteCount: cached, countStyle: .file)
            }
            return "Use \u{201C}Calculate Size\u{201D} to compute"
        }
        if let bytes = values?.totalFileAllocatedSize ?? values?.fileSize {
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        return "—"
    }

    private func formattedDate(_ date: Date?) -> String {
        FileFormatters.long(date)
    }

    @ViewBuilder
    private func kvRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer()
        }
    }
}

// MARK: - POSIX permission bitfield

/// Tiny wrapper around POSIX mode bits for read/write/execute across
/// owner/group/world. Keeps the bit math out of the view code.
struct PosixPermissions: Equatable {
    var mode: UInt16

    static var zero: PosixPermissions { .init(mode: 0) }

    init(mode: UInt16) { self.mode = mode & 0o777 }

    init?(octalString: String) {
        let trimmed = octalString.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 3 || trimmed.count == 4,
              let value = UInt16(trimmed, radix: 8) else { return nil }
        self.mode = value & 0o777
    }

    var octalString: String { String(mode, radix: 8) }

    enum Bit: UInt16 {
        case ownerRead  = 0o400
        case ownerWrite = 0o200
        case ownerExec  = 0o100
        case groupRead  = 0o040
        case groupWrite = 0o020
        case groupExec  = 0o010
        case otherRead  = 0o004
        case otherWrite = 0o002
        case otherExec  = 0o001
    }

    func has(_ bit: Bit) -> Bool { (mode & bit.rawValue) != 0 }

    mutating func set(_ bit: Bit, on: Bool) {
        if on { mode |= bit.rawValue }
        else  { mode &= ~bit.rawValue }
    }
}
