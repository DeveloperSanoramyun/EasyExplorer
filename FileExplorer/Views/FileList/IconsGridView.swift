//
//  IconsGridView.swift
//  FileExplorer
//
//  Large-icon grid view (Windows "Large Icons"). Folders show the
//  system folder icon; files use the QuickLook thumbnail when one's
//  available. Click selects, ⌘-click toggles, double-click opens.
//  Drag from blank space draws a marquee rectangle to lasso multiple
//  items at once — Windows / Finder behaviour. ⌘-drag toggles, ⇧-drag
//  extends the existing selection.
//

import SwiftUI
import AppKit

/// Carries each tile / row's on-screen rect (in the named "lasso"
/// coordinate space) up to the parent so a marquee gesture can
/// hit-test against them. Shared across Icons / Compact / Grouped
/// views so they all use the same hit-testing protocol.
struct ItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct IconsGridView: View {
    @ObservedObject var tab: TabViewModel
    /// Which icon size the grid renders at. The two icon modes
    /// (Icons / Extra Large Icons) share this view to avoid a near-
    /// duplicate struct.
    var sizeMode: FileViewMode = .icons
    @ObservedObject private var clipboard = ClipboardService.shared
    @AppStorage("fe.showExtensions") private var showExtensions: Bool = true

    // Marquee (lasso) state. `itemFrames` is rebuilt on every layout
    // pass by the GeometryReader backings on each tile. `lassoRect`
    // drives the on-screen rubber-band overlay; `baseSelection` lets
    // ⌘/⇧-drag operate on top of the selection that existed before the
    // drag started instead of clobbering it mid-stroke. The gesture and
    // drop logic these feed into is shared with CompactListView/
    // GroupedListView via RowInteraction.swift.
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var lassoRect: CGRect? = nil
    @State private var baseSelection: Set<URL> = []
    /// Throttle for edge auto-scroll — DragGesture fires at the screen
    /// refresh rate, which would scroll dozens of rows per second
    /// without a brake.
    @State private var lastAutoScroll: Date = .distantPast
    /// Finder-style slow-double-click → rename timer. See CompactListView
    /// for the rationale.
    @State private var slowRename = SlowClickRename()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeMode.gridColumnMin,
                            maximum: sizeMode.gridColumnMax),
                  spacing: 6)]
    }

    var body: some View {
        // ScrollViewReader gives us a `scrollTo(id:anchor:)` proxy that
        // the lasso gesture uses to auto-scroll when the marquee touches
        // the viewport edge. Without it, items that aren't already
        // visible can't be lassoed in one stroke.
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                        ForEach(tab.visibleItems) { item in
                            IconTile(
                                item: item,
                                displayName: item.displayName(showingExtensions: showExtensions),
                                iconSize: sizeMode.iconSize,
                                isSelected: tab.selectedIDs.contains(item.url),
                                isCut: clipboard.isCutMarked(item.url),
                                isRenaming: tab.renamingItemID == item.url,
                                onTap: { modifierKeys, wasSelected in
                                    applyRowClick(url: item.url, wasSelected: wasSelected,
                                                  modifiers: modifierKeys,
                                                  tab: tab, slowRename: slowRename)
                                },
                                onDoubleClick: {
                                    slowRename.noteOpened()
                                    slowRename.cancel()
                                    openFileListEntry(item.url, tab: tab)
                                },
                                onCommitRename: { newName in tab.commitRename(item.url, to: newName) },
                                onCancelRename: { tab.cancelRename() }
                            )
                            .id(item.url)
                            .background(lassoFrameReporter(for: item.url))
                            // Multi-selection-aware drag source — see
                            // beginRowDrag.
                            .onDrag { beginRowDrag(item.url, tab: tab) }
                            .folderDropTarget(
                                isFolder: FileSystemService.isReadableDirectory(item.url)
                            ) { droppedURLs in
                                fileListDropInto(item.url, dropped: droppedURLs, tab: tab)
                            }
                            .contextMenu { fileListRowContextMenu(for: item.url, tab: tab) }
                        }
                    }
                    .padding(10)

                    if let rect = lassoRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(
                                Rectangle()
                                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                            )
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: "lasso")
                // `.gesture` (not `.simultaneousGesture` / `.highPriority`)
                // gives child gestures precedence — a drag that starts on
                // a tile still triggers `.draggable` rather than the lasso.
                .gesture(
                    lassoSelectionGesture(
                        itemFrames: itemFrames,
                        lassoRect: $lassoRect,
                        baseSelection: $baseSelection,
                        lastAutoScroll: $lastAutoScroll,
                        flatItems: tab.visibleItems,
                        edgeZone: 40,
                        tab: tab,
                        proxy: proxy
                    )
                )
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            // Stale frames from the previous folder would otherwise leak
            // into hit-testing until the GeometryReaders re-fire.
            .onChange(of: tab.currentURL) { _, _ in
                itemFrames.removeAll()
            }
            // Feed the slow-click rename detector so it can tell a
            // deliberate slow re-click from a double-click / rename-
            // dismiss (mirrors the Details Table detector).
            .onChange(of: tab.selectedIDs) { _, newValue in
                slowRename.selectionChanged(newValue)
            }
            .onChange(of: tab.renamingItemID) { _, _ in
                slowRename.renameDidChange()
            }
            // Drop into the current folder anywhere on the grid.
            .dropDestination(for: URL.self) { droppedURLs, _ in
                fileListDropIntoCurrentFolder(droppedURLs, tab: tab)
            }
            // Clicking blank space deselects (tap only — drag becomes lasso).
            .contentShape(Rectangle())
            .onTapGesture { tab.selectedIDs.removeAll() }
            .contextMenu {
                fileListBlankContextMenu(tab: tab) {
                    Menu("View") {
                        ForEach(FileViewMode.allCases) { mode in
                            Button(mode.displayName) {
                                NotificationCenter.default.post(
                                    name: .feSetViewMode, object: nil,
                                    userInfo: ["mode": mode.rawValue]
                                )
                            }
                        }
                    }
                }
            }
            // Pass the live tile frames so arrow keys navigate the grid
            // in 2D (←→ columns, ↑↓ rows) instead of linear flow order.
            .feKeyboardNavigation(tab: tab, gridFrames: itemFrames)
        }
    }
}

// MARK: - Single tile

private struct IconTile: View {
    let item: FileItem
    let displayName: String
    let iconSize: CGFloat
    let isSelected: Bool
    let isCut: Bool
    let isRenaming: Bool
    /// Tap callback receives modifier keys + whether the tile was
    /// already selected when the tap landed (needed for Finder's
    /// slow-second-click → rename behaviour).
    let onTap: (EventModifiers, Bool) -> Void
    let onDoubleClick: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    /// Bigger tiles deserve bigger thumbnails. 80pt was the historical
    /// boundary between "Icons" and "Extra Large Icons" — match the
    /// `feFont` size logic below so the cache buckets line up.
    private var thumbSizeClass: ThumbnailCache.SizeClass {
        iconSize >= 80 ? .large : .medium
    }

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailIcon(item: item, sizeClass: thumbSizeClass, pointSize: iconSize)
                .allowsHitTesting(false)
            if isRenaming {
                InlineRenameField(initialName: item.name,
                                  onCommit: onCommitRename,
                                  onCancel: onCancelRename)
                    .frame(width: max(100, iconSize + 40))
            } else {
                Text(displayName)
                    .feFont(size: iconSize >= 80 ? 12 : 11)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .padding(6)
        .frame(minHeight: iconSize + 40)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .opacity(isCut ? 0.5 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick() }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                let m = NSEvent.modifierFlags
                let mods: EventModifiers =
                    m.contains(.shift)   ? .shift   :
                    m.contains(.command) ? .command : []
                onTap(mods, isSelected)
            }
        )
    }
}

// MARK: - Inline rename (shared with FileListView's details mode)

/// Finder-faithful inline rename field. Backed by `NSTextField` (not a
/// SwiftUI `TextField`) because we need two things SwiftUI can't give
/// us on macOS 14:
///   1. **Base-name selection** — on entry, only the filename stem is
///      highlighted, leaving the extension untouched, exactly like
///      Finder. Typing replaces just the name; the `.jpg` stays.
///   2. **Commit-on-focus-loss** — clicking away saves the edit (Finder
///      behaviour), while Esc cancels and reverts.
struct InlineRenameField: NSViewRepresentable {
    let initialName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    init(initialName: String,
         onCommit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func makeNSView(context: Context) -> BaseNameTextField {
        let field = BaseNameTextField()
        field.stringValue = initialName
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // Match the list row's scaled font so the text doesn't jump
        // size when entering rename.
        let scale = UserDefaults.standard.double(forKey: "fe.fontScale")
        let pt = 13.0 * (scale == 0 ? 1.0 : scale)
        field.font = .systemFont(ofSize: pt)
        // Accent border to signal edit mode (matches the old SwiftUI
        // look). Layer-based so it sits flush around the field.
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor

        // Become first responder + select the base name once the field
        // is in the view hierarchy.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        context.coordinator.installOutsideClickMonitor(for: field)
        return field
    }

    func updateNSView(_ nsView: BaseNameTextField, context: Context) {
        // Keep the layer border colour correct across appearance
        // (light/dark) changes.
        nsView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        // Refresh the commit/cancel closures so a recycled Coordinator
        // targets the CURRENT item.
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onCancel: onCancel)
    }

    static func dismantleNSView(_ nsView: BaseNameTextField, coordinator: Coordinator) {
        coordinator.removeOutsideClickMonitor()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        // `var` (refreshed in updateNSView) so a recycled Coordinator
        // always commits to the CURRENT item, not the one it was first
        // created for.
        var onCommit: (String) -> Void
        var onCancel: () -> Void
        /// Guards against the commit + end-editing notifications both
        /// firing for a single Enter / Esc.
        private var finished = false
        private weak var field: NSTextField?
        private var outsideClickMonitor: Any?

        init(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        /// Single commit entry point — reads the field's CURRENT text
        /// and commits, NOT relying on first-responder. A SwiftUI Table
        /// steals first-responder from the in-cell NSTextField on
        /// re-render, so `makeFirstResponder(nil)` often fails to fire
        /// `controlTextDidEndEditing`; reading `stringValue` directly is
        /// reliable. Idempotent via `finished`.
        func commitNow() {
            guard !finished else { return }
            finished = true
            removeOutsideClickMonitor()
            onCommit(field?.stringValue ?? "")
        }

        /// A click anywhere OUTSIDE the rename field commits the edit —
        /// the reliable cross-view way to dismiss, since an NSTextField
        /// inside a SwiftUI `Table` / `LazyVStack` cell doesn't always
        /// resign first-responder when another row or the file's icon
        /// is clicked. Clicks inside the field are left alone (cursor
        /// positioning).
        func installOutsideClickMonitor(for field: NSTextField) {
            // CRITICAL: a SwiftUI `Table` recycles cells, so this
            // Coordinator can be REUSED for a later rename. Reset the
            // one-shot `finished` flag (and drop any stale monitor) so
            // the new edit can actually commit — otherwise a leftover
            // `finished == true` makes `controlTextDidEndEditing`
            // early-return and the rename never saves / dismisses.
            finished = false
            removeOutsideClickMonitor()
            self.field = field
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let field = self.field, !self.finished,
                          let win = field.window, win == event.window else { return }
                    let p = field.convert(event.locationInWindow, from: nil)
                    if !field.bounds.contains(p) {
                        // Commit directly from the field value — see commitNow().
                        self.commitNow()
                    }
                }
                return event
            }
        }

        func removeOutsideClickMonitor() {
            if let m = outsideClickMonitor {
                NSEvent.removeMonitor(m)
                outsideClickMonitor = nil
            }
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Esc → cancel + revert (don't let editing-ended commit).
                guard !finished else { return true }
                finished = true
                removeOutsideClickMonitor()
                onCancel()
                return true
            }
            return false   // let Enter / Tab take their default path
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Fires on Enter, Tab, or focus loss (when the field IS the
            // first responder). Esc has already set `finished` above.
            commitNow()
        }
    }
}

/// NSTextField subclass that selects only the filename stem (excluding
/// the extension) when it becomes first responder.
final class BaseNameTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            // Defer one hop so the field editor is attached before we
            // set its selection.
            DispatchQueue.main.async { [weak self] in
                self?.selectBaseName()
            }
        }
        return ok
    }

    private func selectBaseName() {
        guard let editor = currentEditor() else { return }
        let name = stringValue as NSString
        // Work in NSString (UTF-16) units throughout so the range lines
        // up with the field editor's expectations.
        let extLength = (name.pathExtension as NSString).length
        // Folders / extension-less / dotfiles (".gitignore") → select
        // the whole name; otherwise everything up to the final dot.
        let length: Int
        if extLength == 0 || name.length <= extLength + 1 {
            length = name.length
        } else {
            length = name.length - extLength - 1
        }
        editor.selectedRange = NSRange(location: 0, length: length)
    }
}
