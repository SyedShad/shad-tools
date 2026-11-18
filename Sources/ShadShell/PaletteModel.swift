import ShadCore
import AppKit
import ServiceManagement
import SwiftUI

@MainActor final class PaletteModel: ObservableObject {
    let edition: Edition
    let shortcuts: Shortcuts
    private let features: [(module: FeatureModule, session: FeatureSession)]
    var standaloneWindow: (() -> Void)? { edition.isSuite ? nil : features.first?.session.openStandalone }
    var tabScope: FeatureModule? {
        guard edition.isSuite, scope == nil, !settings else { return nil }
        return edition.modules.first(where: \.homeTabTarget)
    }

    func tileColor(for command: ToolCommand) -> Color {
        let module = edition.modules.first { command.id.hasPrefix($0.commandPrefix) || command.id == "group." + $0.id }
        return module.map { Color(nsColor: $0.tileColor) } ?? .gray
    }

    func shouldTerminate() -> NSApplication.TerminateReply {
        for feature in features {
            if let reply = feature.session.shouldTerminate?(), reply != .terminateNow { return reply }
        }
        return .terminateNow
    }

    @Published var query = "" { didSet { if oldValue != query { refresh(keepSelection: false) } } }
    @Published var scope: FeatureModule?
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
        features = edition.modules.map { ($0, $0.start()) }
        recent = preferences.stringArray(forKey: "recentCommands") ?? []
        scope = edition.standaloneModule
        rebuild()
    }
    var current: ToolCommand? { rows.indices.contains(selected) ? rows[selected] : nil }
    var title: String { settings ? "Keyboard shortcuts" : (scope?.category ?? "Tools") }
    var prompt: String {
        if settings { return "Find a shortcut…" }
        if features.contains(where: { $0.session.search != nil && (scope == nil || scope == $0.module) }) { return "Search apps, files and commands…" }
        return "Search " + (scope?.category ?? "commands") + "…"
    }

    private var categories: [ToolCommand] {
        edition.modules.filter { $0.homeCommand == nil }.map { item in
            ToolCommand(id: "group." + item.id, title: item.category, subtitle: item.detail, symbol: item.symbol, group: item.group) { [weak self] in
                self?.selectScope(item)
            }
        }
    }

    func rebuild() {
        var seen = Set<String>()
        catalog = features.flatMap { module, session in
            session.commands().filter { $0.id.hasPrefix(module.commandPrefix) && seen.insert($0.id).inserted }
        }
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
            let offline = shortcuts.savedNames.filter { id, _ in
                !active.contains(id) && features.contains { id.hasPrefix($0.module.commandPrefix) }
            }.sorted { $0.value < $1.value }.map { id, name in
                ToolCommand(id: id, title: name, subtitle: "Unavailable · Edit or remove its saved shortcut", symbol: "keyboard", group: "Settings", perform: {})
            }
            let launchers = standaloneWindow == nil ? [launcher] : []
            found = rankedCommands(launchers + catalog + offline, query: query)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = searchResults(for: "")
            let direct = Set(edition.modules.compactMap(\.homeCommand))
            let tools = scope == nil ? categories + catalog.filter { direct.contains($0.id) } : []
            let commands = catalog.filter { $0.id.hasPrefix(scope?.commandPrefix ?? "") }
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
            let dynamic = searchResults(for: query)
            let staticRows = catalog.filter { $0.id.hasPrefix(scope?.commandPrefix ?? "") }
            let navigation = scope == nil ? categories : []
            var seen = Set<String>()
            let candidates = (navigation + staticRows + dynamic).filter { seen.insert($0.id).inserted }
            found = rankedCommands(candidates, query: query)
        }
        if sectionHeaders.isEmpty, let first = found.first {
            sectionHeaders[first.id] = query.isEmpty ? title : "Results"
        }
        rows = Array(found.prefix(120))
        if let target = actionTarget, !rows.contains(where: { $0.id == target }) { closeActions() }
        selected = old.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    private func searchResults(for query: String) -> [ToolCommand] {
        features.flatMap { module, session -> [ToolCommand] in
            guard let search = session.search else { return [] }
            if let scope, scope != module {
                _ = search("")
                return []
            }
            return search(query).filter { $0.id.hasPrefix(module.commandPrefix) }
        }
    }

    func selectScope(_ value: FeatureModule?) {
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
        _ = searchResults(for: "")
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
            list.append(contentsOf: command.actions.map(PaletteAction.feature))
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
        case .feature(let action):
            dismiss?()
            action.perform()
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
        else if settings { note = nil; selectScope(edition.standaloneModule) }
        else if !query.isEmpty { query = "" }
        else if scope != nil && edition.isSuite { selectScope(nil) }
        else { dismiss?() }
    }
    func closed() {
        closeActions(focusSearch: false)
        recording = nil
        note = nil
        query = ""
        _ = searchResults(for: "")
    }
    func reset() {
        note = nil
        selectScope(edition.standaloneModule)
    }
}
