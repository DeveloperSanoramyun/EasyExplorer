//
//  TabBar.swift
//  FileExplorer
//
//  Windows-11-style tab strip across the top of the window. Each tab
//  shows the active folder's name; hovering reveals an × close button;
//  click selects, middle-click closes, drag reorders. A trailing "+"
//  button creates a new tab.
//

import SwiftUI
import AppKit

struct TabBar: View {
    @ObservedObject var window: WindowState
    /// URL of the tab currently being dragged (when non-nil). We use a
    /// transferable URL so AppKit's NSItemProvider plumbing accepts it;
    /// the real intent is just "this tab id is moving".
    @State private var draggingTabID: UUID? = nil
    /// Opens a new window pre-seeded with a URL — see `FileExplorerApp`'s
    /// `WindowGroup(for: URL.self)` and `ContentView.init(tornOffTabURL:)`.
    /// Backs the "Move to New Window" tab context-menu item below.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(window.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabChip(
                            tab: tab,
                            isActive: index == window.activeIndex,
                            isDragging: draggingTabID == tab.id,
                            onSelect: { window.selectTab(at: index) },
                            onClose:  { window.closeTab(at: index) },
                            onMiddleClick: { window.closeTab(at: index) }
                        )
                        .contextMenu {
                            Button("New Tab") { window.newTab() }
                            Divider()
                            Button("Close Tab") { window.closeTab(at: index) }
                            // Dragging a tab out to tear it off needs a
                            // native NSDraggingSession to know the drop
                            // point relative to the window, which isn't
                            // reliably testable without live UI access —
                            // this menu command is the equivalent,
                            // reliable entry point. Disabled for the
                            // window's only tab, same as Safari/Chrome:
                            // there'd be nothing left behind to tear off
                            // FROM.
                            Button("Move to New Window") {
                                let url = tab.currentURL
                                openWindow(value: url)
                                window.closeTab(at: index)
                            }
                            .disabled(window.tabs.count <= 1)
                        }
                        .onDrag {
                            draggingTabID = tab.id
                            // SwiftUI's `.onDrag` doesn't surface
                            // cancellation, so a drag the user aborts
                            // (Esc, drop outside any target) would
                            // leave the chip stuck at half opacity
                            // forever. Auto-reset after 4s if the
                            // drop delegate never claimed it.
                            let id = tab.id
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 4_000_000_000)
                                if draggingTabID == id {
                                    draggingTabID = nil
                                }
                            }
                            return NSItemProvider(object: tab.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TabDropDelegate(
                                window: window,
                                destinationIndex: index,
                                draggingTabID: $draggingTabID
                            )
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Button {
                window.newTab()
            } label: {
                Image(systemName: "plus")
                    .feFont(size: 11, weight: .medium)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New tab (\u{2318}T)")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

// MARK: - Drag-drop reorder

/// Routes the cross-tab drop into `WindowState.moveTab(from:to:)`. The
/// drag identifier is the tab's UUID; we resolve it back to an index on
/// drop, so the source position is always current even if the user
/// scrolls the strip between drag-start and drop.
private struct TabDropDelegate: DropDelegate {
    let window: WindowState
    let destinationIndex: Int
    @Binding var draggingTabID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingTabID = nil }
        guard let sourceID = draggingTabID,
              let sourceIndex = window.tabs.firstIndex(where: { $0.id == sourceID }),
              sourceIndex != destinationIndex
        else { return false }
        window.moveTab(from: sourceIndex, to: destinationIndex)
        return true
    }

    func dropEntered(info: DropInfo) {}
    func dropExited(info: DropInfo) {}
}

// MARK: - Single tab chip

private struct TabChip: View {
    @ObservedObject var tab: TabViewModel
    let isActive: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMiddleClick: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .feFont(size: 10)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(title)
                .feFont(size: 12, weight: isActive ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)

            // × close button: visible when active OR hovering, hidden
            // otherwise — same as Safari/Chrome on macOS.
            if isActive || hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .feFont(size: 8, weight: .bold)
                        .padding(3)
                        .background(
                            Circle().fill(hovering ? Color.secondary.opacity(0.25) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Close tab (\u{2318}W)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 100, maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Color(nsColor: .controlBackgroundColor)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.secondary.opacity(0.3) : .clear, lineWidth: 0.5)
        )
        .opacity(isDragging ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        // Middle-click close — same convention every browser uses.
        // SwiftUI's gesture system doesn't fire for middle clicks, so we
        // hook a local NSEvent monitor scoped to this view's bounds.
        .background(MiddleClickCatcher(action: onMiddleClick))
    }

    private var title: String {
        let url = tab.currentURL
        if url.path == NSHomeDirectory() { return "Home" }
        if url.path == "/" { return "Macintosh HD" }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}

// MARK: - Middle-click hit area

/// SwiftUI doesn't expose middle-button mouse events, so we install a
/// transparent NSView whose -mouseDown is invoked on otherMouseDown
/// (button 2). Sitting in the background means it doesn't steal taps
/// from the parent — only middle-clicks land here.
private struct MiddleClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onMiddleClick = action
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onMiddleClick = action
    }

    final class CatcherView: NSView {
        var onMiddleClick: (() -> Void)?

        override func otherMouseDown(with event: NSEvent) {
            // Middle button = NSEvent.ButtonNumber 2 (left = 0, right = 1).
            if event.buttonNumber == 2 {
                onMiddleClick?()
            } else {
                super.otherMouseDown(with: event)
            }
        }

        override var acceptsFirstResponder: Bool { false }
    }
}
