//
//  PermissionGuideDialog.swift
//  FileExplorer
//
//  First-launch onboarding for macOS's TCC sandbox prompts. macOS
//  pops a separate "X would like to access folder Y" dialog for each
//  protected directory (Desktop, Documents, Downloads, Pictures, …)
//  the first time the user navigates there. With Full Disk Access
//  granted once, every one of those prompts goes away — including
//  the rebuild-induced ones every developer sees during iteration.
//
//  Shown automatically on the first launch (via @AppStorage flag)
//  and re-openable any time via Help → "Folder Access…".
//

import SwiftUI

struct PermissionGuideDialog: View {
    /// Dismiss action injected from the .sheet presentation. We don't
    /// touch the AppStorage flag here — the caller's `onDismiss` does
    /// that so the dialog can be shown manually (via the menu) without
    /// re-flipping the "first launch is over" bit.
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grant Folder Access")
                        .font(.title2.weight(.semibold))
                    Text("macOS asks permission for each protected folder. Granting Full Disk Access once unblocks everything.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Two clearly-labelled buttons — primary path on top, the
            // narrower per-folder pane below for users who'd rather
            // approve Desktop/Documents/Downloads individually.
            VStack(alignment: .leading, spacing: 12) {
                bulletRow(
                    icon: "checkmark.shield.fill",
                    title: "Full Disk Access (recommended)",
                    body: "One click — every folder works. macOS won't ask again, even after rebuilds.",
                    action: PermissionGuide.openFullDiskAccessSettings,
                    actionLabel: "Open Full Disk Access…"
                )
                bulletRow(
                    icon: "folder.badge.gearshape",
                    title: "Files & Folders (per folder)",
                    body: "Approve Desktop / Documents / Downloads individually if you'd rather keep tighter scope.",
                    action: PermissionGuide.openFilesAndFoldersSettings,
                    actionLabel: "Open Files & Folders…"
                )
            }

            Divider()

            // Pro tip — explains why prompts come back when rebuilding
            // from Xcode, so devs know the deeper fix.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                Text("Rebuilds reset permissions? Sign with a Personal Team in Xcode → Signing & Capabilities so macOS keeps trusting the same identity across builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Renders one row of [icon] + [title / body / action button].
    @ViewBuilder
    private func bulletRow(icon: String,
                           title: String,
                           body: String,
                           action: @escaping () -> Void,
                           actionLabel: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.semibold))
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(actionLabel, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }
}
