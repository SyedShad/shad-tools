import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class PaletteModel: ObservableObject {
    let edition: Edition
    let shortcuts: Shortcuts
    let search: SearchTool?
    let audio: AudioTool?
    let drives: DrivesTool?
    let color: ColorTool?
    let windows: WindowTool?
    let capture: CaptureTool?
    @Published var query = "" { didSet { if oldValue != query { refresh(keepSelection: false) } } }
    @Published var scope: Edition?
    @Published var rows = [ToolCommand]()
    @Published var selected = 0
    @Published var actionTarget: String?
    @Published var actionQuery = "" { didSet { if oldValue != actionQuery { selectedAction = 0 } } }
    @Published var selectedAction = 0
    @Published private(set) var favorites: [String]
    private(set) var sectionHeaders = [String: String]()
    @Published var settings = false
    @Published var recording: String?
    @Published var note: String?
    @Published var loginEnabled = false
    @Published var appearance: PaletteAppearance {
        didSet {
            preferences.set(appearance.rawValue, forKey: "paletteAppearance")
            applyAppearance?()
        }
    }
    var applyAppearance: (() -> Void)?
    private var catalog = [ToolCommand]()
    private var recent: [String]
    private var navigated = false
    private let preferences: UserDefaults
    var dismiss: (() -> Void)?
    var open: (() -> Void)?
    var refocus: (() -> Void)?

    init(_ edition: Edition, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        appearance = PaletteAppearance(rawValue: preferences.string(forKey: "paletteAppearance") ?? "") ?? .system
        favorites = preferences.stringArray(forKey: "favoriteCommands") ?? []
        self.edition = edition
        shortcuts = Shortcuts(edition, preferences: preferences)
        search = edition.includesSearch ? SearchTool() : nil
        audio = [.suite, .audio].contains(edition) ? AudioTool() : nil
        drives = [.suite, .drives].contains(edition) ? DrivesTool() : nil
        color = [.suite, .color].contains(edition) ? ColorTool() : nil
        windows = [.suite, .windows].contains(edition) ? WindowTool() : nil
        capture = [.suite, .capture].contains(edition) ? CaptureTool() : nil
        recent = preferences.stringArray(forKey: "recentCommands") ?? []
        scope = edition == .suite ? nil : edition
        rebuild()
    }
    var canJumpToCapture: Bool { edition == .suite && scope == nil && !settings }
    var current: ToolCommand? { rows.indices.contains(selected) ? rows[selected] : nil }
    var title: String { settings ? "Keyboard shortcuts" : (scope?.category ?? "Tools") }
    var prompt: String {
        if settings { return "Find a shortcut…" }
        if scope == .search || (scope == nil && edition.includesSearch) { return "Search apps, files and commands…" }
        return "Search " + (scope?.category ?? "commands") + "…"
    }

    private var categories: [ToolCommand] {
        Edition.allCases.filter { $0 != .suite }.map { item in
            ToolCommand(id: "group." + item.rawValue, title: item.category, subtitle: item.detail, symbol: item.symbol, group: item.group) { [weak self] in
                self?.selectScope(item)
            }
        }
    }

    func rebuild() {
        catalog = (search?.commands() ?? []) + (audio?.commands() ?? [])
        catalog += drives?.commands() ?? []
        catalog += color?.commands() ?? []
        catalog += windows?.commands() ?? []
        catalog += capture?.commands() ?? []
        shortcuts.reconcile(Set(catalog.map(\.id)).union(["app.open"]))
        refresh()
    }

    func refresh(keepSelection: Bool = true) {
        if !keepSelection { navigated = false }
        let old = navigated ? current?.id : nil
        var found: [ToolCommand]
        sectionHeaders.removeAll(keepingCapacity: true)
        if settings {
            let launcher = ToolCommand(id: "app.open", title: "Open " + edition.title, subtitle: "Show or hide the palette from any application", symbol: "command", group: "Settings", perform: {})
            let active = Set(catalog.map(\.id)).union([launcher.id])
            let offline = shortcuts.savedNames.filter { !active.contains($0.key) }.sorted { $0.value < $1.value }.map { id, name in
                ToolCommand(id: id, title: name, subtitle: "Unavailable · Edit or remove its saved shortcut", symbol: "keyboard", group: "Settings", perform: {})
            }
            found = rankedCommands([launcher] + catalog + offline, query: query)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = search?.results(for: "")
            let tools = scope == nil ? categories : []
            let commands = catalog.filter { scope == nil || $0.group == scope?.group }
            let available = tools + commands
            let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            found = []
            func append(_ items: [ToolCommand], section: String) {
                let next = items.filter { seen.insert($0.id).inserted }
                if let first = next.first { sectionHeaders[first.id] = section }
                found += next
            }
            append(favorites.compactMap { byID[$0] }, section: "Favorites")
            append(Array(recent.compactMap { byID[$0] }.prefix(5)), section: "Suggestions")
            append(tools, section: "Tools")
            append(commands, section: scope?.category ?? "Commands")
        } else {
            let allowsFiles = scope == nil || scope == .search
            let dynamic = search?.results(for: allowsFiles ? query : "") ?? []
            let staticRows = catalog.filter { scope == nil || $0.group == scope?.group }
            let navigation = scope == nil ? categories : []
            found = rankedCommands(navigation + staticRows + dynamic, query: query)
        }
        if sectionHeaders.isEmpty, let first = found.first {
            sectionHeaders[first.id] = query.isEmpty ? title : "Results"
        }
        rows = Array(found.prefix(120))
        if let target = actionTarget, !rows.contains(where: { $0.id == target }) { closeActions() }
        selected = old.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    func selectScope(_ value: Edition?) {
        closeActions(focusSearch: false)
        settings = false
        recording = nil
        scope = value
        query = ""
        refresh(keepSelection: false)
        refocus?()
    }

    func showSettings() {
        closeActions(focusSearch: false)
        settings = true
        recording = nil
        note = nil
        loginEnabled = SMAppService.mainApp.status == .enabled
        _ = search?.results(for: "")
        query = ""
        refresh(keepSelection: false)
        refocus?()
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if !loginEnabled && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { note = error.localizedDescription }
    }

    func move(_ direction: Int) {
        if actionTarget != nil {
            selectedAction = max(0, min(filteredActions.count - 1, selectedAction + direction))
            return
        }
        guard !rows.isEmpty else { return }
        navigated = true
        selected = max(0, min(rows.count - 1, selected + direction))
    }

    func nextSection(forward: Bool) {
        guard actionTarget == nil, !rows.isEmpty else { return }
        let headings = rows.indices.filter { sectionHeaders[rows[$0].id] != nil }
        if forward { selected = headings.first { $0 > selected } ?? (rows.count - 1) }
        else { selected = headings.last { $0 < selected } ?? 0 }
        navigated = true
    }

    func secondaryAction() {
        if actionTarget == nil { toggleActions() }
        if let action = filteredActions.dropFirst().first { performAction(action) }
    }

    func execute(_ command: ToolCommand) {
        if settings { record(command); return }
        if command.id.hasPrefix("group.") { command.perform(); return }
        if catalog.contains(where: { $0.id == command.id }) {
            recent.removeAll { $0 == command.id }
            recent.insert(command.id, at: 0)
            recent = Array(recent.prefix(12))
            preferences.set(recent, forKey: "recentCommands")
        }
        dismiss?()
        command.perform()
    }

    func hotkey(_ id: String) {
        if id == "app.open" { open?(); return }
        if let action = catalog.first(where: { $0.id == id }) {
            TargetApplication.capture()
            dismiss?()
            action.perform()
        }
    }

    func canRecord(_ command: ToolCommand) -> Bool {
        settings || command.id == "app.open" || catalog.contains { $0.id == command.id }
    }

    var actionCommand: ToolCommand? {
        guard let actionTarget else { return nil }
        return rows.first { $0.id == actionTarget }
    }

    var filteredActions: [PaletteAction] {
        guard let command = actionCommand else { return [] }
        var list: [PaletteAction] = [.run]
        if !settings {
            if canRecord(command) { list.append(.shortcut) }
            if catalog.contains(where: { $0.id == command.id }) || command.id.hasPrefix("group.") {
                list.append(.favorite)
            }
            if command.fileURL != nil { list += [.reveal, .copyPath] }
            list.append(.settings)
        }
        let needle = actionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? list : list.filter { title($0, for: command).localizedCaseInsensitiveContains(needle) }
    }

    func title(_ action: PaletteAction, for command: ToolCommand) -> String {
        action.title(for: command, editing: settings, favorite: favorites.contains(command.id))
    }

    func toggleActions() {
        if actionTarget != nil { closeActions(); return }
        guard let command = current else { return }
        actionTarget = command.id
        actionQuery = ""
        selectedAction = 0
        navigated = true
    }

    func closeActions(focusSearch: Bool = true) {
        guard actionTarget != nil else { return }
        actionTarget = nil
        actionQuery = ""
        selectedAction = 0
        if focusSearch { refocus?() }
    }

    func confirmSelection() {
        if actionTarget != nil {
            let list = filteredActions
            if list.indices.contains(selectedAction) { performAction(list[selectedAction]) }
        } else if let command = current {
            execute(command)
        }
    }

    func performAction(_ action: PaletteAction) {
        guard let command = actionCommand else { return }
        closeActions()
        switch action {
        case .run: execute(command)
        case .shortcut: record(command)
        case .favorite:
            if favorites.contains(command.id) { favorites.removeAll { $0 == command.id } }
            else { favorites.append(command.id) }
            preferences.set(favorites, forKey: "favoriteCommands")
            refresh()
        case .reveal:
            if let url = command.fileURL { dismiss?(); NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .copyPath:
            if let url = command.fileURL {
                dismiss?()
                NSPasteboard.general.clearContents()
                Feedback.show(NSPasteboard.general.setString(url.path, forType: .string) ? "Copied path" : "Couldn’t copy the path")
            }
        case .settings: showSettings()
        }
    }

    func record(_ command: ToolCommand) {
        guard canRecord(command) else { return }
        recording = command.id
        note = nil
    }
    func save(_ chord: KeyChord?) {
        guard let id = recording else { return }
        let name = rows.first(where: { $0.id == id })?.title ?? id
        if let error = shortcuts.change(id, title: name, to: chord) { note = error }
        else { recording = nil; note = nil; rebuild(); refocus?() }
    }

    func back() {
        if recording != nil { recording = nil; note = nil; refocus?() }
        else if actionTarget != nil { closeActions() }
        else if settings { note = nil; selectScope(edition == .suite ? nil : edition) }
        else if !query.isEmpty { query = "" }
        else if scope != nil && edition == .suite { selectScope(nil) }
        else { dismiss?() }
    }
    func closed() {
        closeActions(focusSearch: false)
        recording = nil
        note = nil
        query = ""
        _ = search?.results(for: "")
    }
    func reset() {
        note = nil
        selectScope(edition == .suite ? nil : edition)
    }
}
