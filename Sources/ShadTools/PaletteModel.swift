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
    @Published var query = "" { didSet { if oldValue != query { refresh(keepSelection: false) } } }
    @Published var scope: Edition?
    @Published var rows = [ToolCommand]()
    @Published var selected = 0
    @Published var settings = false
    @Published var recording: String?
    @Published var note: String?
    @Published var loginEnabled = false
    private var catalog = [ToolCommand]()
    private var recent: [String]
    private var navigated = false
    var dismiss: (() -> Void)?
    var open: (() -> Void)?
    var refocus: (() -> Void)?

    init(_ edition: Edition) {
        self.edition = edition
        shortcuts = Shortcuts(edition)
        search = edition.includesSearch ? SearchTool() : nil
        audio = [.suite, .audio].contains(edition) ? AudioTool() : nil
        drives = [.suite, .drives].contains(edition) ? DrivesTool() : nil
        color = [.suite, .color].contains(edition) ? ColorTool() : nil
        windows = [.suite, .windows].contains(edition) ? WindowTool() : nil
        recent = UserDefaults.standard.stringArray(forKey: "recentCommands") ?? []
        scope = edition == .suite ? nil : edition
        rebuild()
    }
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
        shortcuts.reconcile(Set(catalog.map(\.id)).union(["app.open"]))
        refresh()
    }

    func refresh(keepSelection: Bool = true) {
        if !keepSelection { navigated = false }
        let old = navigated ? current?.id : nil
        var found: [ToolCommand]
        if settings {
            let launcher = ToolCommand(id: "app.open", title: "Open " + edition.title, subtitle: "Show or hide the palette from any application", symbol: "command", group: "Settings", perform: {})
            let active = Set(catalog.map(\.id)).union([launcher.id])
            let offline = shortcuts.savedNames.filter { !active.contains($0.key) }.sorted { $0.value < $1.value }.map { id, name in
                ToolCommand(id: id, title: name, subtitle: "Unavailable · Edit or remove its saved shortcut", symbol: "keyboard", group: "Settings", perform: {})
            }
            found = rankedCommands([launcher] + catalog + offline, query: query)
        } else if scope == nil && query.trimmingCharacters(in: .whitespaces).isEmpty {
            _ = search?.results(for: "")
            found = categories
            found += recent.prefix(3).compactMap { id in catalog.first { $0.id == id } }
        } else {
            let allowsFiles = scope == nil || scope == .search
            let dynamic = search?.results(for: allowsFiles ? query : "") ?? []
            let staticRows = catalog.filter { scope == nil || $0.group == scope?.group }
            let navigation = scope == nil ? categories : []
            found = rankedCommands(navigation + staticRows + dynamic, query: query)
        }
        rows = Array(found.prefix(120))
        selected = old.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
    }

    func selectScope(_ value: Edition?) {
        settings = false
        recording = nil
        scope = value
        query = ""
        refresh(keepSelection: false)
        refocus?()
    }

    func showSettings() {
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
        guard !rows.isEmpty else { return }
        navigated = true
        selected = max(0, min(rows.count - 1, selected + direction))
    }

    func execute(_ command: ToolCommand) {
        if settings { record(command); return }
        if command.id.hasPrefix("group.") { command.perform(); return }
        if catalog.contains(where: { $0.id == command.id }) {
            recent.removeAll { $0 == command.id }
            recent.insert(command.id, at: 0)
            recent = Array(recent.prefix(12))
            UserDefaults.standard.set(recent, forKey: "recentCommands")
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
        else if settings { note = nil; selectScope(edition == .suite ? nil : edition) }
        else if !query.isEmpty { query = "" }
        else if scope != nil && edition == .suite { selectScope(nil) }
        else { dismiss?() }
    }
    func closed() {
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
