import AppKit
import SwiftUI

struct ClipboardUIAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var shortcut = ""
    let run: @MainActor () -> Void
}

enum ClipboardMenu { case actions, formats, recent, filters }

enum ClipboardEditor {
    case rename, edit, snippet
    var multiline: Bool { self == .edit }
    var title: String {
        switch self {
        case .rename: return "Rename Entry"
        case .edit: return "Edit Content"
        case .snippet: return "Save as Snippet"
        }
    }
}

enum ClipboardDeletion: Equatable {
    case all
    case recent(Int)

    static let intervals = [5, 15, 30, 60, 1440]
    static func duration(_ minutes: Int) -> String {
        minutes == 60 ? "hour" : minutes == 1440 ? "24 hours" : "\(minutes) minutes"
    }

    var title: String {
        switch self {
        case .all: return "Delete all clipboard entries?"
        case .recent(let minutes): return "Delete entries from the last \(Self.duration(minutes))?"
        }
    }
}

@MainActor extension HistoryBrowser {
    var pasteTitle: String { tool?.pasteTargetName.map { "Paste to " + $0 } ?? "Paste to Active App" }

    func pasteKeepingOpen() { if let selected { tool?.paste(selected, keepOpen: true) } }
    func togglePin() { if let selected, !selected.isSnippet { tool?.setPinned(!selected.isPinned, for: selected) } }

    func resetOverlays() {
        menu = nil
        actionQuery = ""
        actionIndex = 0
        editor = nil
        deletion = nil
        draft = ""
    }

    func cancelOverlay() {
        resetOverlays()
        focusSearch?()
    }

    func openMenu(_ next: ClipboardMenu) {
        if next == .actions && selected == nil { return }
        resetOverlays()
        menu = next
        DispatchQueue.main.async { [weak self] in self?.focusActions?() }
    }

    func closeMenu() { cancelOverlay() }

    func backMenu() {
        if menu == .formats || menu == .recent { openMenu(.actions) }
        else { closeMenu() }
    }

    func beginEdit(_ next: ClipboardEditor) {
        guard let selected else { return }
        if next == .snippet {
            guard case .text = content, selected.itemCount == 1 || inspection.group?.textCount == selected.itemCount else { return }
        }
        let value: String
        if next == .edit {
            guard selected.itemCount == 1, case .text(let text) = content else { return }
            value = text
        } else { value = selected.title }
        resetOverlays()
        draft = value
        editor = next
    }

    var canSaveDraft: Bool {
        guard let editor else { return false }
        return editor.multiline ? !draft.isEmpty : !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveDraft() {
        guard let editor, let selected, let tool, canSaveDraft else { return }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editor {
        case .edit: tool.edit(selected, text: draft)
        case .rename: tool.rename(selected, to: name)
        case .snippet: tool.saveSnippet(selected, named: name)
        }
        cancelOverlay()
    }

    func confirmDeletion() {
        guard let deletion else { return }
        switch deletion {
        case .all: tool?.clear()
        case .recent(let minutes): tool?.clear(since: Date().addingTimeInterval(-Double(minutes) * 60))
        }
        cancelOverlay()
    }

    private func actions(for entry: ClipboardEntry, tool: ClipboardTool) -> [ClipboardUIAction] {
        let grouped = entry.itemCount > 1
        let group = inspection.group
        let completeText = !grouped || group?.textCount == entry.itemCount
        let completeFiles = !grouped || group?.fileCount == entry.itemCount
        var items: [ClipboardUIAction] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ shortcut: String = "", _ run: @escaping @MainActor () -> Void) {
            items.append(ClipboardUIAction(id: id, title: title, symbol: symbol, shortcut: shortcut, run: run))
        }
        add("paste", pasteTitle, "arrow.turn.down.left", "↵") { tool.paste(entry) }
        add("copy", "Copy to Clipboard", "doc.on.doc", "⌘↵") { tool.copy(entry) }
        add("stay", "Paste and Keep Window Open", "rectangle.on.rectangle", "⌥↵") { tool.paste(entry, keepOpen: true) }
        if !formats.isEmpty { add("formats", "Paste as…", "square.stack.3d.up") { self.openMenu(.formats) } }
        if case .text = content, formats.contains(NSPasteboard.PasteboardType.string.rawValue) {
            add("plain", tool.pasteTargetName.map { "Paste as Plain Text to " + $0 } ?? "Paste as Plain Text",
                "text.alignleft") { tool.paste(entry, as: NSPasteboard.PasteboardType.string.rawValue) }
        }
        add("share", "Share…", "square.and.arrow.up") {
            if let anchor = self.hostPanel?.contentView { tool.share(entry, from: anchor) }
        }
        if !grouped, case .text = content {
            add("edit", "Edit Content…", "pencil") { self.beginEdit(.edit) }
        }
        add("rename", "Rename Entry…", "character.cursor.ibeam", "⌘E") { self.beginEdit(.rename) }
        items += ClipboardExtraActions.actions(for: entry, content: content, tool: tool).filter { completeText || $0.id == "chat" }
        if (!grouped && (entry.kind == .link || entry.kind == .email)) || (completeFiles && entry.kind == .files) {
            let title = entry.kind == .email ? "Compose Email" : entry.kind == .link ? "Open Link" : "Open Files"
            add("open", title, "arrow.up.forward.app") { tool.open(entry) }
        }
        if entry.kind == .image || entry.kind == .files || grouped {
            add("openWith", "Open With…", "arrow.up.forward.square") { tool.openWith(entry) }
            add("reveal", "Show in Finder", "folder") { tool.reveal(entry) }
            if (!grouped && entry.kind == .image) || group?.canAnnotate == true {
                add("annotate", "Annotate in Preview", "pencil.tip.crop.circle") { tool.annotate(entry) }
            }
            add("quickLook", "Quick Look", "eye") { tool.quickLook(entry) }
        }
        if entry.kind == .files && completeFiles { add("paths", "Copy File Paths", "link") { tool.copyFilePaths(entry) } }
        if !entry.isSnippet {
            add("pin", entry.isPinned ? "Unpin Entry" : "Pin Entry", entry.isPinned ? "pin.slash" : "pin", "⌘.") {
                tool.setPinned(!entry.isPinned, for: entry)
            }
            if completeText, case .text = content {
                add("snippet", grouped ? "Save Combined Text as Snippet…" : "Save as Snippet…", "text.quote") { self.beginEdit(.snippet) }
            }
        }
        add("save", grouped ? "Save as Files…" : "Save as File…", "square.and.arrow.down") { tool.saveAsFile(entry) }
        if (!grouped && entry.kind == .image) || (group?.imageCount ?? 0) > 0 {
            let multiple = (group?.imageCount ?? 0) > 1
            add("ocr", multiple ? "Copy Text from Images" : "Copy Text from Image", "text.viewfinder") { tool.copyRecognizedText(entry) }
            add("qr", multiple ? "Copy Text from QR Codes" : "Copy Text from QR Code", "qrcode.viewfinder") { tool.copyQRCode(entry) }
        }
        add("delete", entry.isSnippet ? "Delete Snippet" : "Delete Entry", "trash", "⌘X") { tool.remove(entry) }
        if !entry.isSnippet {
            add("recent", "Delete Recent Entries…", "clock.arrow.circlepath", "⇧⌘X") { self.openMenu(.recent) }
            add("all", "Delete All Entries…", "trash") { self.deletion = .all }
        }
        return items
    }

    var availableActions: [ClipboardUIAction] {
        guard let menu else { return [] }
        let items: [ClipboardUIAction]
        switch menu {
        case .actions:
            guard let selected, let tool else { return [] }
            items = actions(for: selected, tool: tool)
        case .formats:
            guard let selected, let tool else { return [] }
            items = formats.map { type in
                ClipboardUIAction(id: type, title: ClipboardPasteboard.formatName(type), symbol: "doc.on.clipboard") {
                    tool.paste(selected, as: type)
                }
            }
        case .recent:
            items = ClipboardDeletion.intervals.map { minutes in
                ClipboardUIAction(id: String(minutes), title: "Last " + ClipboardDeletion.duration(minutes), symbol: "clock") {
                    self.deletion = .recent(minutes)
                }
            }
        case .filters:
            items = HistoryFilter.allCases.map { type in
                ClipboardUIAction(id: type.rawValue, title: type.rawValue, symbol: filter == type ? "checkmark.circle.fill" : "circle") {
                    self.filter = type
                }
            }
        }
        let search = actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    func moveAction(_ delta: Int) {
        actionIndex = min(max(0, availableActions.count - 1), max(0, actionIndex + delta))
    }

    func runSelectedAction() {
        let items = availableActions
        if items.indices.contains(actionIndex) { run(items[actionIndex]) }
    }

    func run(_ action: ClipboardUIAction) {
        closeMenu()
        action.run()
    }
}

private struct ClipboardActionSearch: NSViewRepresentable {
    @ObservedObject var browser: HistoryBrowser

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let browser: HistoryBrowser
        init(_ browser: HistoryBrowser) { self.browser = browser }
        @MainActor func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { browser.actionQuery = field.stringValue }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(browser) }
    func makeNSView(context: Context) -> NSTextField {
        let field = HistoryTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.placeholderString = "Search for actions…"
        field.setAccessibilityLabel("Search for actions")
        field.delegate = context.coordinator
        browser.focusActions = { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != browser.actionQuery { field.stringValue = browser.actionQuery }
    }
}

struct ClipboardActionPalette: View {
    @ObservedObject var browser: HistoryBrowser
    private var menuTitle: String {
        switch browser.menu {
        case .formats: return "Paste as"
        case .recent: return "Delete Recent Entries"
        case .filters: return "Filter by Type"
        default: return browser.selected?.historyTitle ?? "Actions"
        }
    }

    var body: some View {
        GeometryReader { box in
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.055).contentShape(Rectangle()).onTapGesture { browser.closeMenu() }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if browser.menu == .formats || browser.menu == .recent {
                            Button { browser.backMenu() } label: { Image(systemName: "chevron.backward") }
                                .accessibilityLabel("Back")
                        }
                        Text(menuTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    }.foregroundStyle(.secondary).padding(.horizontal, 13).frame(height: 34)
                    Divider()
                    let actions = browser.availableActions
                    if actions.isEmpty {
                        Text("No matching actions").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(20)
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                                        Button {
                                            browser.run(action)
                                        } label: {
                                            HStack(spacing: 9) {
                                                Image(systemName: action.symbol).frame(width: 18)
                                                Text(action.title).lineLimit(1)
                                                Spacer(minLength: 2)
                                                Text(action.shortcut).font(.caption).foregroundStyle(.secondary)
                                            }.padding(.horizontal, 8).frame(height: 30)
                                                .background(index == browser.actionIndex ? Color.primary.opacity(0.11) : .clear,
                                                            in: RoundedRectangle(cornerRadius: 6))
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain).font(.system(size: 13))
                                        .accessibilityLabel(action.title)
                                        .accessibilityAddTraits(index == browser.actionIndex ? .isSelected : [])
                                        .id(action.id)
                                    }
                                }.padding(5)
                            }
                            .onChange(of: browser.actionIndex) { value in
                                if actions.indices.contains(value) { scroll.scrollTo(actions[value].id) }
                            }
                        }.frame(height: min(box.size.height - 140, CGFloat(min(actions.count, 8)) * 32 + 10))
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        ClipboardActionSearch(browser: browser).frame(height: 24)
                        Button { browser.closeMenu() } label: { Text("esc").font(.caption).foregroundStyle(.secondary) }
                            .accessibilityLabel("Close actions")
                    }.padding(.horizontal, 12).frame(height: 37)
                }.buttonStyle(.plain)
                .frame(width: min(335, box.size.width - 30))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.18), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
                .padding(.trailing, 12).padding(.bottom, 12)
                .accessibilityElement(children: .contain).accessibilityLabel(menuTitle)
            }
        }
    }
}

struct ClipboardEditorOverlay: View {
    @ObservedObject var browser: HistoryBrowser
    @FocusState private var editing: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture { browser.cancelOverlay() }
            VStack(alignment: .leading, spacing: 12) {
                if let editor = browser.editor {
                    Text(editor.title).font(.headline)
                    if editor.multiline {
                        TextEditor(text: $browser.draft).font(.body).focused($editing)
                            .accessibilityLabel("Entry content").frame(height: 145)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.13)))
                    } else {
                        TextField(editor == .snippet ? "Snippet name" : "Entry name", text: $browser.draft)
                            .focused($editing)
                    }
                } else if let deletion = browser.deletion {
                    Text(deletion.title).font(.headline)
                    Text(deletion == .all ? "This removes your clipboard history, including pinned entries. Your saved snippets are kept." : "This removes unpinned entries copied in this period.").font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { browser.cancelOverlay() }
                    if browser.editor != nil {
                        Button("Save") { browser.saveDraft() }.buttonStyle(.borderedProminent).disabled(!browser.canSaveDraft)
                    } else {
                        Button("Delete", role: .destructive) { browser.confirmDeletion() }
                    }
                }
            }.padding(20).frame(width: 355).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.15)))
                .shadow(color: .black.opacity(0.24), radius: 12, y: 3)
        }.onAppear { if browser.editor != nil { DispatchQueue.main.async { editing = true } } }
    }
}
