//
//  PaneBrowser.swift
//  FileExplorer
//
//  One self-contained folder browser: address bar + search filter row +
//  file list (+ optional preview). Used both as the single main pane
//  and, in split (dual-pane) view, twice side by side so the user can
//  drag / copy / move files between two folders.
//
//  Drag-and-drop between panes needs no special wiring — each pane's
//  FileListView already exposes `.draggable` sources and folder-row /
//  background `.dropDestination` targets keyed to its own tab's URL, so
//  a drag from the left pane lands in the right pane's folder.
//

import SwiftUI
import AppKit

struct PaneBrowser: View {
    @ObservedObject var tab: TabViewModel
    /// True while this is the focused pane (drives the accent bar and
    /// tells the rest of the app which folder commands act on). Always
    /// true in single-pane mode.
    var isActive: Bool = true
    /// Whether the window is currently in split view — gates the
    /// active-pane accent bar (no bar when there's only one pane).
    var isSplit: Bool = false
    /// Show the Quick Look preview beside the list (single-pane only).
    var showPreview: Bool = false
    /// Called when the user interacts with this pane, to focus it.
    var onActivate: () -> Void = {}

    /// Click-to-activate watcher. Reference type held in @State so the
    /// NSEvent monitor survives re-renders (same pattern as the Details
    /// view's TableRenameClickDetector).
    @State private var activator = PaneClickActivator()

    var body: some View {
        VStack(spacing: 0) {
            // A 2pt accent bar marks the focused pane in split view.
            if isSplit {
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            AddressBar(tab: tab)
            // Filter chip row collapses itself when no search is active.
            SearchFilterBar(tab: tab)
            Divider()
            // Transient operation-error banner (trash failure, busy
            // transfer…). Folder-READ errors still use the full-pane
            // overlay in FileListView; this banner keeps the listing
            // visible and interactive for mere op failures.
            if let opError = tab.opErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(opError)
                        .font(.callout)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                    Button {
                        tab.opErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.12))
                Divider()
            }
            HSplitView {
                FileListView(tab: tab)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if showPreview {
                    PreviewPane(tab: tab)
                        // No hard width cap — drag the divider to make
                        // the preview as wide as you like (the list keeps
                        // its 320pt minimum), so it can reach ~half the
                        // window. Default stays compact via idealWidth.
                        .frame(minWidth: 240, idealWidth: 340,
                               maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        // Fill the available area so the file list expands and the
        // chrome (tab strip / status bar) stays pinned top & bottom —
        // without this the VStack sized to content and floated.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Focus this pane on a USER click anywhere in it — via an
        // NSEvent monitor, NOT a TapGesture: the Details view's `Table`
        // is AppKit-backed and swallows ancestor SwiftUI gestures, so a
        // tap-based activation never fired there and `activeSide` stayed
        // stuck on one pane (⌘C/⌘V then targeted the wrong folder). The
        // probe view mirrors this pane's frame so the monitor can
        // hit-test clicks against it. (We must NOT key off `selectedIDs`
        // — an external delete in the background pane prunes its
        // selection programmatically, which would steal focus away from
        // the pane the user is in.)
        .background(PaneProbeView { activator.setProbe($0) })
        .onAppear { activator.start(onActivate: onActivate) }
        .onDisappear { activator.stop() }
        // Per-pane progress sheet. Presenting from the PANE — not from a
        // window-level modifier bound to `window.activeTab` — means a
        // transfer running in the BACKGROUND pane still gets its dialog,
        // and switching panes mid-transfer can't re-bind the sheet (or
        // route its Close button) to the wrong tab.
        .sheet(item: progressBinding) { _ in
            if let p = tab.transferProgress {
                ProgressDialog(progress: p) {
                    tab.dismissTransferDialog()
                }
            }
        }
        // Dim the inactive pane very slightly so the focused one reads
        // as "live" without being distracting.
        .opacity(isSplit && !isActive ? 0.85 : 1.0)
    }

    private var progressBinding: Binding<TransferProgressID?> {
        Binding(
            get: {
                // Stable id derived from the progress object so SwiftUI
                // doesn't see a "new" sheet on every render and flicker.
                // Gated on `transferDialogVisible`: a fast op keeps
                // `transferProgress` set (for hasActiveTransfer) but
                // never shows a dialog; success auto-clears the flag
                // after a brief "Done" flash; errors keep it up.
                guard let p = tab.transferProgress,
                      tab.transferDialogVisible else { return nil }
                return TransferProgressID(refID: ObjectIdentifier(p))
            },
            set: { if $0 == nil { tab.dismissTransferDialog() } }
        )
    }
}

private struct TransferProgressID: Identifiable, Equatable {
    let refID: ObjectIdentifier
    var id: ObjectIdentifier { refID }
}

// MARK: - Click-to-activate (NSEvent monitor)

/// Activates a pane when any mouse-down lands inside it. A local NSEvent
/// monitor sees every click in the app BEFORE the view under the cursor
/// handles it — including clicks inside AppKit-backed views (`Table`,
/// `NSTextField`) that never propagate to SwiftUI ancestor gestures.
/// The event is always returned unchanged, so selection / editing /
/// double-click behaviour is untouched; this only updates pane focus.
@MainActor
final class PaneClickActivator {
    private var monitor: Any?
    private weak var probe: NSView?
    private var onActivate: () -> Void = {}

    /// The pane-sized NSView used to scope clicks to this pane.
    func setProbe(_ view: NSView) { probe = view }

    func start(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // Local monitors fire for EVERY window of the app —
                // only react to clicks in the window hosting this pane.
                guard let self, let probe = self.probe,
                      let win = probe.window, event.window == win else { return }
                let p = probe.convert(event.locationInWindow, from: nil)
                if probe.bounds.contains(p) { self.onActivate() }
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Transparent NSView planted as the pane's `.background`, mirroring its
/// frame so the activator can hit-test clicks. Same pattern as the
/// Details view's RenameProbeView.
private struct PaneProbeView: NSViewRepresentable {
    let onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // `view.window` is nil until the view joins the hierarchy —
        // defer one hop so the activator gets a fully-attached view.
        DispatchQueue.main.async { onView(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
