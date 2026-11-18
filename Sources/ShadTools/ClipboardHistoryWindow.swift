import AppKit
import ApplicationServices
import Combine
import ImageIO
import SwiftUI

enum HistoryFilter: String, CaseIterable {
    case all = "All Types"
    case text = "Text"
    case images = "Images"
    case files = "Files"
    case links = "Links"
    case emails = "Emails"
    case colors = "Colors"
    case pinned = "Pinned"
    case snippets = "Snippets"

    func includes(_ entry: ClipboardEntry) -> Bool {
        switch self {
        case .all: return !entry.isSnippet
        case .text: return entry.kind == .text && !entry.isSnippet
        case .images: return entry.kind == .image && !entry.isSnippet
        case .files: return entry.kind == .files && !entry.isSnippet
        case .links: return entry.kind == .link && !entry.isSnippet
        case .emails: return entry.kind == .email && !entry.isSnippet
        case .colors: return entry.kind == .color && !entry.isSnippet
        case .pinned: return entry.isPinned && !entry.isSnippet
        case .snippets: return entry.isSnippet
        }
    }
}

enum HistoryPreview {
    case loading
    case text(String)
    case image(CGImage)
    case files([URL])
    case unavailable
}

@MainActor
final class HistoryBrowser: ObservableObject {
    weak var tool: ClipboardTool?
    @Published var query = "" { didSet { if oldValue != query { updateResults(invalidateSelection: true) } } }
    @Published var filter: HistoryFilter = .all { didSet { if oldValue != filter { updateResults(invalidateSelection: true) } } }
    @Published private(set) var rows: [ClipboardEntry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var preview: HistoryPreview = .loading
    @Published private(set) var total = 0
    @Published private(set) var paused = false
    @Published private(set) var issue: String?
    @Published var menu: ClipboardMenu?
    @Published var actionQuery = "" { didSet { if oldValue != actionQuery { actionIndex = 0 } } }
    @Published var actionIndex = 0
    @Published var editor: ClipboardEditor?
    @Published var draft = ""
    @Published var deletion: ClipboardDeletion?
    @Published var inspection = ClipboardInspection()
    @Published var formats: [String] = []
    private(set) var content: ClipboardContent?
    weak var hostPanel: NSPanel?
    var focusActions: (() -> Void)?
    var isOverlayOpen: Bool { menu != nil || editor != nil || deletion != nil }
    var focusSearch: (() -> Void)?

    private var presented = false
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var all: [ClipboardEntry] = []
    private var snippets: [ClipboardEntry] = []
    private let thumbnails = NSCache<NSString, NSImage>()

    init(tool: ClipboardTool) {
        self.tool = tool
        thumbnails.countLimit = 100
        tool.$entries.sink { [weak self] entries in
            guard let self else { return }
            all = entries
            total = entries.filter { !$0.isSnippet }.count
            if presented { updateResults() }
        }.store(in: &subscriptions)
        tool.$snippets.sink { [weak self] snippets in
            guard let self else { return }
            self.snippets = snippets
            if presented && filter == .snippets { updateResults() }
        }.store(in: &subscriptions)
        tool.$paused.sink { [weak self] in self?.paused = $0 }.store(in: &subscriptions)
        tool.$issue.sink { [weak self] in self?.issue = $0 }.store(in: &subscriptions)
    }

    var selected: ClipboardEntry? { rows.first { $0.id == selectedID } }

    func appear() {
        query = ""
        filter = .all
        presented = true
        updateResults()
    }

    func disappear() {
        presented = false
        searchTask?.cancel()
        previewTask?.cancel()
        resetOverlays()
        selectedID = nil
        content = nil
        inspection = ClipboardInspection()
        formats = []
        preview = .loading
        rows = []
        thumbnails.removeAllObjects()
    }

    private func updateResults(invalidateSelection: Bool = false) {
        guard presented else { return }
        searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { apply(filter == .snippets ? snippets : all); return }
        // A new query invalidates the old selection immediately. A background
        // refresh of the same query should preserve an open action or edit form.
        if invalidateSelection {
            rows = []
            select(nil)
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled, let self, let tool else { return }
            let matches = filter == .snippets ? await tool.snippets(matching: query) : await tool.entries(matching: query)
            guard !Task.isCancelled, presented else { return }
            apply(matches)
        }
    }

    private func apply(_ entries: [ClipboardEntry]) {
        let previousIndex = rows.firstIndex(where: { $0.id == selectedID }) ?? 0
        let original = selected
        rows = entries.filter(filter.includes)
        if let current = selected {
            if current != original { loadPreview(current) }
            return
        }
        let next = rows.isEmpty ? nil : rows[min(previousIndex, rows.count - 1)].id
        select(next)
    }

    func move(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex(where: { $0.id == selectedID }) ?? 0
        select(rows[max(0, min(rows.count - 1, index + offset))].id)
    }

    func select(_ id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        resetOverlays()
        loadPreview(selected)
    }

    private func loadPreview(_ entry: ClipboardEntry?) {
        previewTask?.cancel()
        preview = .loading
        content = nil
        inspection = ClipboardInspection()
        formats = []
        guard let entry, let tool else { return }
        previewTask = Task { [weak self, weak tool] in
            guard let tool else { return }
            guard let content = await tool.content(for: entry) else {
                if !Task.isCancelled { self?.preview = .unavailable }
                return
            }
            guard !Task.isCancelled else { return }
            let inspectionTask = Task.detached(priority: .userInitiated) { ClipboardInspection.inspect(content) }
            let result = await withTaskCancellationHandler {
                await inspectionTask.value
            } onCancel: { inspectionTask.cancel() }
            guard !Task.isCancelled, self?.selectedID == entry.id else { return }
            self?.content = content
            self?.inspection = result
            self?.preview = result.preview
            let available = await tool.formats(for: entry)
            guard !Task.isCancelled, self?.selectedID == entry.id else { return }
            self?.formats = available
        }
    }

    var countLabel: String {
        if filter == .snippets { return rows.count == 1 ? "1 snippet" : "\(rows.count) snippets" }
        if filter != .all || !query.isEmpty { return "\(rows.count) of \(total) items" }
        return total == 1 ? "1 item" : "\(total) items"
    }

    func thumbnail(for entry: ClipboardEntry) -> NSImage? {
        guard let bytes = entry.thumbnail else { return nil }
        if let image = thumbnails.object(forKey: entry.id as NSString) { return image }
        guard let image = NSImage(data: bytes) else { return nil }
        thumbnails.setObject(image, forKey: entry.id as NSString)
        return image
    }

    func paste() { if let selected { tool?.paste(selected) } }
    func copy() { if let selected { tool?.copy(selected) } }
    func remove() { if let selected { tool?.remove(selected) } }

}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardHistoryWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let browser: HistoryBrowser
    private var monitor: Any?
    private var suspendedForPaste = false

    init(tool: ClipboardTool) {
        browser = HistoryBrowser(tool: tool)
        panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 555),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        browser.hostPanel = panel
        panel.title = "Clipboard History"
        panel.setAccessibilityLabel("Clipboard History")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: HistoryView(browser: browser, close: { [weak self] in self?.hide() }))
    }

    func toggle() { panel.isVisible && panel.isKeyWindow ? hide() : show() }

    func show() {
        suspendedForPaste = false
        browser.appear()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(850, frame.width - 24), height: min(555, frame.height - 28))
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + (frame.height - size.height) * 0.62,
                                  width: size.width, height: size.height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // AppKit finishes mounting the hosting view and assigning its initial responder on the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, panel.isKeyWindow else { return }
            browser.focusSearch?()
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) == true }
                return handled ? nil : event
            }
        }
    }

    func suspendForPaste() {
        suspendedForPaste = true
        panel.orderOut(nil)
    }

    func resumeAfterPaste() {
        guard suspendedForPaste else { return }
        suspendedForPaste = false
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        browser.focusSearch?()
    }

    func hide() {
        suspendedForPaste = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if panel.isVisible { panel.orderOut(nil) }
        browser.disappear()
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible && !suspendedForPaste && panel.attachedSheet == nil && NSApp.modalWindow == nil { hide() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, event.window == panel else { return false }
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let enter = event.keyCode == 36 || event.keyCode == 76
        if browser.editor != nil {
            if event.keyCode == 53 { browser.cancelOverlay(); return true }
            if enter && (modifiers == .command || (browser.editor?.multiline == false && modifiers.isEmpty)) {
                browser.saveDraft(); return true
            }
            return performEditingShortcut(event)
        }
        if browser.deletion != nil {
            if event.keyCode == 53 { browser.cancelOverlay(); return true }
            return enter
        }
        if browser.menu != nil {
            if event.keyCode == 53 { browser.backMenu(); return true }
            if modifiers == .command && key == "k" { browser.closeMenu(); return true }
            if modifiers.isEmpty {
                switch event.keyCode {
                case 125: browser.moveAction(1); return true
                case 126: browser.moveAction(-1); return true
                case 36, 76: browser.runSelectedAction(); return true
                default: break
                }
            }
            return performEditingShortcut(event)
        }
        if modifiers == [.command, .shift], key == "x" { browser.openMenu(.recent); return true }
        if modifiers == .option, enter { browser.pasteKeepingOpen(); return true }
        if modifiers == .command {
            if enter { browser.copy(); return true }
            if event.keyCode == 51 { browser.remove(); return true }
            switch key {
            case "k": browser.openMenu(.actions)
            case "p": browser.openMenu(.filters)
            case ".": browser.togglePin()
            case "e": browser.beginEdit(.rename)
            case "f": browser.focusSearch?()
            case "w": hide()
            case "x":
                if let field = panel.firstResponder as? NSTextView, field.selectedRange().length > 0 {
                    return performEditingShortcut(event)
                }
                browser.remove()
            default: return performEditingShortcut(event)
            }
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 125: browser.move(1)
        case 126: browser.move(-1)
        case 36, 76: browser.paste()
        case 53: hide()
        default: return false
        }
        return true
    }

    private func performEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let selector = ["a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:", "z": "undo:"][key]
        else { return false }
        return NSApp.sendAction(NSSelectorFromString(selector), to: panel.firstResponder, from: self)
    }
}

final class HistoryTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.isKeyWindow else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct HistorySearchField: NSViewRepresentable {
    @ObservedObject var browser: HistoryBrowser

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let browser: HistoryBrowser
        init(_ browser: HistoryBrowser) { self.browser = browser }
        @MainActor func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { browser.query = field.stringValue }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(browser) }
    func makeNSView(context: Context) -> NSTextField {
        let field = HistoryTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21)
        field.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(string: "Search clipboard history…",
            attributes: [.font: NSFont.systemFont(ofSize: 21), .foregroundColor: NSColor.secondaryLabelColor])
        field.setAccessibilityLabel("Search clipboard history")
        field.delegate = context.coordinator
        browser.focusSearch = { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != browser.query { field.stringValue = browser.query }
    }
}

struct ClipboardTextPreview: NSViewRepresentable {
    let id: String
    let text: String
    final class Coordinator { var id: String?; var text: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.font = .systemFont(ofSize: 15)
            view.textColor = .labelColor
            view.textContainerInset = NSSize(width: 0, height: 0)
            view.textContainer?.lineFragmentPadding = 0
            view.layoutManager?.allowsNonContiguousLayout = true
            view.setAccessibilityLabel("Text preview")
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.id != id || context.coordinator.text != text, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.id = id
        context.coordinator.text = text
        view.string = text
        view.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

private struct HistoryView: View {
    @ObservedObject var browser: HistoryBrowser
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var solid
    private let corner = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private var surface: Color { scheme == .dark ? Color(white: 0.117) : Color(white: 0.969) }
    private var secondary: Color { scheme == .dark ? Color(white: 0.74) : Color(white: 0.36) }
    private var selection: Color { scheme == .dark ? .white.opacity(0.105) : .black.opacity(0.075) }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .medium)).accessibilityHidden(true)
                    HistorySearchField(browser: browser).frame(maxWidth: .infinity).frame(height: 30)
                    Picker("Filter by type", selection: $browser.filter) {
                        ForEach(HistoryFilter.allCases, id: \.self) { filter in Text(filter.rawValue).tag(filter) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().help("Filter by type")
                    Button(action: close) { Image(systemName: "xmark.circle").font(.system(size: 16)) }
                        .buttonStyle(.plain).accessibilityLabel("Close clipboard history").help("Close (Esc)")
                }
                .foregroundStyle(secondary).padding(.horizontal, 20).frame(height: 65)
                Divider()
                if let issue = browser.issue {
                    Label(issue, systemImage: "exclamationmark.circle").font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 7)
                    Divider()
                }
                if browser.rows.isEmpty { empty }
                else {
                    GeometryReader { box in
                        HStack(spacing: 0) {
                            historyList.frame(width: (box.size.width * 0.375).rounded())
                            Divider()
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                Divider()
                footer
            }
            .accessibilityHidden(browser.isOverlayOpen)
            if browser.menu != nil { ClipboardActionPalette(browser: browser) }
            if browser.editor != nil || browser.deletion != nil { ClipboardEditorOverlay(browser: browser) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { surface.opacity(solid ? 1 : 0.95).background(.regularMaterial) }
        .clipShape(corner)
        .overlay(corner.strokeBorder(.primary.opacity(0.14), lineWidth: 0.7).allowsHitTesting(false))
    }

    private var empty: some View {
        let filtered = !browser.query.isEmpty || browser.filter != .all
        return VStack(spacing: 9) {
            Spacer()
            Image(systemName: filtered ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 29, weight: .light)).foregroundStyle(secondary)
            Text(filtered ? "No matching items" : browser.paused ? "Clipboard history is paused" : "Your clipboard history is empty")
                .font(.system(size: 16, weight: .semibold))
            if !filtered {
                Text(browser.paused ? "Resume history to collect new copies." : "Copy text, images or files to see them here.")
                    .font(.system(size: 13)).foregroundStyle(secondary)
                if browser.paused { Button("Resume History") { browser.tool?.setPaused(false) } }
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(browser.rows.enumerated()), id: \.element.id) { index, entry in
                        if index == 0 || sectionTitle(browser.rows[index-1]) != sectionTitle(entry) {
                            Text(sectionTitle(entry)).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(secondary).padding(.horizontal, 10).frame(height: 27)
                                .accessibilityAddTraits(.isHeader)
                        }
                        row(entry).id(entry.id)
                    }
                }.padding(8)
            }
            .onChange(of: browser.selectedID) { id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func sectionTitle(_ entry: ClipboardEntry) -> String {
        if entry.isSnippet { return "Snippets" }
        if entry.isPinned { return "Pinned" }
        let date = entry.copiedAt
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = browser.selectedID == entry.id
        return Button { browser.select(entry.id) } label: {
            HStack(spacing: 10) {
                if entry.kind == .image, let thumb = browser.thumbnail(for: entry) {
                    Image(nsImage: thumb).resizable().scaledToFill().frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                } else {
                    Image(systemName: entry.kind.historySymbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(entry.kind.historyTint)
                        .frame(width: 28, height: 28)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                Text(entry.historyTitle).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if entry.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(secondary).accessibilityLabel("Pinned") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 42)
                .background(selected ? selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.select(entry.id); browser.paste() })
        .accessibilityLabel(entry.historyTitle).accessibilityValue(entry.kind.historyLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Actions…") { browser.select(entry.id); browser.openMenu(.actions) }
            Button(browser.pasteTitle) { browser.tool?.paste(entry) }
            Button("Copy to Clipboard") { browser.tool?.copy(entry) }
            Divider()
            if !entry.isSnippet { Button(entry.isPinned ? "Unpin Entry" : "Pin Entry") { browser.tool?.setPinned(!entry.isPinned, for: entry) } }
            Button("Rename Entry…") { browser.select(entry.id); browser.beginEdit(.rename) }
            Button("Delete Entry", role: .destructive) { browser.tool?.remove(entry) }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = browser.selected {
            ClipboardInspector(browser: browser, entry: entry)
        }
    }

    private var footer: some View {
        HStack(spacing: 11) {
            Menu {
                Button(browser.paused ? "Resume History" : "Pause History") { browser.tool?.setPaused(!browser.paused) }
                if !AXIsProcessTrusted() {
                    Button("Enable Direct Paste…") {
                        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                    }
                }
                Divider()
                Button("Delete Selected Item") { browser.remove() }.disabled(browser.selected == nil)
                Button("Delete Recent Entries…") { browser.openMenu(.recent) }
                Button("Delete All Entries…", role: .destructive) { browser.deletion = .all }.disabled(browser.total == 0)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("History actions").help("History actions")
            Text(browser.paused ? "History paused" : browser.countLabel)
                .font(.system(size: 12)).foregroundStyle(secondary)
            Spacer(minLength: 8)
            Button { browser.paste() } label: {
                HStack(spacing: 6) { Text(browser.pasteTitle).fontWeight(.semibold); key("↵") }
            }.accessibilityLabel(browser.pasteTitle).disabled(browser.selected == nil)
            Divider().frame(height: 16)
            Button { browser.openMenu(.actions) } label: {
                HStack(spacing: 6) { Text("Actions"); key("⌘K") }
            }.accessibilityLabel("Actions").help("Actions (⌘K)").disabled(browser.selected == nil)
        }
        .buttonStyle(.plain).font(.system(size: 13)).padding(.horizontal, 18).frame(height: 49)

    }

    private func key(_ key: String) -> some View {
        Text(key).font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
            .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 18)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.14), lineWidth: 0.65))
            .accessibilityHidden(true)
    }

}
