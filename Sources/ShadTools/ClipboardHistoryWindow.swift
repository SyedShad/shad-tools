import AppKit
import ApplicationServices
import Combine
import ImageIO
import SwiftUI

private enum HistoryFilter: String, CaseIterable {
    case all = "All Types"
    case text = "Text"
    case images = "Images"

    func includes(_ entry: ClipboardEntry) -> Bool {
        self == .all || (self == .text && entry.kind == .text) || (self == .images && entry.kind == .image)
    }
}

private enum HistoryPreview {
    case loading
    case text(String)
    case image(CGImage)
    case unavailable
}

@MainActor
private final class HistoryBrowser: ObservableObject {
    weak var tool: ClipboardTool?
    @Published var query = "" { didSet { if oldValue != query { updateResults() } } }
    @Published var filter: HistoryFilter = .all { didSet { if oldValue != filter { updateResults() } } }
    @Published private(set) var rows: [ClipboardEntry] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var preview: HistoryPreview = .loading
    @Published private(set) var total = 0
    @Published private(set) var paused = false
    @Published private(set) var issue: String?
    @Published var confirmingClear = false
    var focusSearch: (() -> Void)?

    private var presented = false
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var all: [ClipboardEntry] = []
    private let thumbnails = NSCache<NSString, NSImage>()

    init(tool: ClipboardTool) {
        self.tool = tool
        thumbnails.countLimit = 100
        tool.$entries.sink { [weak self] entries in
            guard let self else { return }
            all = entries
            total = entries.count
            if presented { updateResults() }
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
        confirmingClear = false
        selectedID = nil
        preview = .loading
        rows = []
        thumbnails.removeAllObjects()
    }

    private func updateResults() {
        guard presented else { return }
        searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { apply(all); return }
        // While searching, a previous selection must not be pasted by a quick Return.
        rows = []
        select(nil)
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled, let self, let tool else { return }
            let matches = await tool.entries(matching: query)
            guard !Task.isCancelled, presented else { return }
            apply(matches)
        }
    }

    private func apply(_ entries: [ClipboardEntry]) {
        let previousIndex = rows.firstIndex(where: { $0.id == selectedID }) ?? 0
        rows = entries.filter(filter.includes)
        if rows.contains(where: { $0.id == selectedID }) { return }
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
        previewTask?.cancel()
        preview = .loading
        guard let entry = selected, let tool else { return }
        previewTask = Task { [weak self, weak tool] in
            guard let content = await tool?.content(for: entry), !Task.isCancelled else {
                if !Task.isCancelled { self?.preview = .unavailable }
                return
            }
            let next: HistoryPreview
            switch content {
            case .text(let text): next = .text(text)
            case .image(let data):
                // Display a bounded preview, while copying and pasting use the full PNG.
                let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1500, kCGImageSourceShouldCacheImmediately: true]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
                next = image.map(HistoryPreview.image) ?? .unavailable
            }
            guard !Task.isCancelled, self?.selectedID == entry.id else { return }
            self?.preview = next
        }
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
    func clear() { confirmingClear = false; tool?.clear() }
}

private final class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardHistoryWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let browser: HistoryBrowser
    private var monitor: Any?

    init(tool: ClipboardTool) {
        browser = HistoryBrowser(tool: tool)
        panel = ClipboardPanel(contentRect: NSRect(x: 0, y: 0, width: 824, height: 522),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
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
        browser.appear()
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let size = NSSize(width: min(824, frame.width - 24), height: min(522, frame.height - 28))
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

    func hide() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if panel.isVisible { panel.orderOut(nil) }
        browser.disappear()
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible { hide() }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow, event.window == panel else { return false }
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if browser.confirmingClear {
            if event.keyCode == 53 { browser.confirmingClear = false; browser.focusSearch?(); return true }
            // Destructive clearance always requires the explicit Clear History button.
            return [36, 76].contains(event.keyCode)
        }
        if modifiers == .command {
            switch event.keyCode {
            case 36, 76: browser.copy()
            case 51: browser.remove()
            default:
                guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
                if key == "f" { browser.focusSearch?() }
                else if key == "w" { hide() }
                else if let selector = ["a": "selectAll:", "c": "copy:", "x": "cut:", "v": "paste:"][key] {
                    return NSApp.sendAction(NSSelectorFromString(selector), to: panel.firstResponder, from: self)
                } else { return false }
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
}

private final class HistoryTextField: NSTextField {
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

private struct ClipboardTextPreview: NSViewRepresentable {
    let id: String
    let text: String
    final class Coordinator { var id: String? }
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
        guard context.coordinator.id != id, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.id = id
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
    private var surface: Color { scheme == .dark ? Color(white: 0.235) : Color(white: 0.969) }
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
                            historyList.frame(width: (box.size.width * 0.45).rounded())
                            Divider()
                            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                Divider()
                footer
            }
            .accessibilityHidden(browser.confirmingClear)
            if browser.confirmingClear { confirmation }
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
                Text(browser.paused ? "Resume history to collect new copies." : "Copy text or an image to see it here.")
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
                        if index == 0 || !Calendar.current.isDate(browser.rows[index-1].copiedAt, inSameDayAs: entry.copiedAt) {
                            Text(sectionTitle(entry.copiedAt)).font(.system(size: 12, weight: .semibold))
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

    private func sectionTitle(_ date: Date) -> String {
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
                    Image(systemName: entry.kind == .image ? "photo" : "text.alignleft").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(entry.kind == .image ? Color.mint : secondary)
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                }
                Text(entry.title).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 42)
                .background(selected ? selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.select(entry.id); browser.paste() })
        .accessibilityLabel(entry.title).accessibilityValue(entry.kind == .image ? "Image" : "Text")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Paste into Previous App") { browser.select(entry.id); browser.paste() }
            Button("Copy to Clipboard") { browser.select(entry.id); browser.copy() }
            Divider()
            Button("Delete Item", role: .destructive) { browser.tool?.remove(entry) }
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = browser.selected {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch browser.preview {
                    case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .unavailable:
                        Text("Preview unavailable").font(.callout).foregroundStyle(secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .text(let text): ClipboardTextPreview(id: entry.id, text: text)
                    case .image(let image):
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityElement().accessibilityLabel("Image preview")
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().padding(.horizontal, 18)
                HStack(spacing: 8) {
                    Label(entry.kind == .text ? "Text" : "Image", systemImage: entry.kind == .text ? "text.alignleft" : "photo")
                    Text("·").accessibilityHidden(true)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                    Spacer(minLength: 4)
                    Text(entry.copiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                }.font(.system(size: 11.5)).foregroundStyle(secondary)
                    .padding(.horizontal, 19).frame(height: 40)
            }
            .background(.primary.opacity(0.016))
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
                Button("Clear History…", role: .destructive) { browser.confirmingClear = true }.disabled(browser.total == 0)
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("History actions").help("History actions")
            Text(browser.paused ? "History paused" : browser.total == 1 ? "1 item" : "\(browser.total) items")
                .font(.system(size: 12)).foregroundStyle(secondary)
            Spacer(minLength: 8)
            Button { browser.copy() } label: {
                HStack(spacing: 6) { Text("Copy"); key("⌘↵") }
            }.accessibilityLabel("Copy to clipboard").disabled(browser.selected == nil)
            Divider().frame(height: 16)
            Button { browser.paste() } label: {
                HStack(spacing: 6) { Text("Paste").fontWeight(.semibold); key("↵") }
            }.accessibilityLabel("Paste into previous app").disabled(browser.selected == nil)
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

    private var confirmation: some View {
        ZStack {
            Color.black.opacity(0.20).contentShape(Rectangle()).onTapGesture { browser.confirmingClear = false }
            VStack(alignment: .leading, spacing: 10) {
                Text("Clear clipboard history?").font(.headline)
                Text("This deletes all saved text and images from Shad’s history.").font(.callout).foregroundStyle(secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { browser.confirmingClear = false; browser.focusSearch?() }
                    Button("Clear History", role: .destructive) { browser.clear(); browser.focusSearch?() }
                }.padding(.top, 5)
            }.padding(20).frame(width: 325).background(.thickMaterial, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.18), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.2), radius: 14, y: 4)
        }
    }
}
