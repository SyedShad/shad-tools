import AppKit

/// A feature owns its metadata and command namespace. Creating its descriptor starts no services.
package struct FeatureModule: Identifiable, Equatable {
    package let id: String
    package let appName: String
    package let category: String
    package let group: String
    package let detail: String
    package let tileColor: NSColor
    package let homeTabTarget: Bool
    package let symbol: String
    package let commandPrefix: String
    package let launcher: KeyChord?
    package let commandShortcuts: [String: KeyChord]
    package let homeCommand: String?
    package let start: @MainActor () -> FeatureSession

    package init(id: String, appName: String, category: String, group: String,
                 detail: String, symbol: String, tileColor: NSColor = .systemGray,
                 homeTabTarget: Bool = false, commandPrefix: String? = nil,
                 launcher: KeyChord? = nil, commandShortcuts: [String: KeyChord] = [:],
                 homeCommand: String? = nil, start: @escaping @MainActor () -> FeatureSession) {
        self.id = id
        self.appName = appName
        self.category = category
        self.group = group
        self.detail = detail
        self.tileColor = tileColor
        self.homeTabTarget = homeTabTarget
        self.symbol = symbol
        self.commandPrefix = (commandPrefix ?? id) + "."
        self.launcher = launcher
        self.commandShortcuts = commandShortcuts
        self.homeCommand = homeCommand
        self.start = start
    }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// These hooks keep the host independent of a feature's implementation and frameworks.
@MainActor package struct FeatureSession {
    package let commands: () -> [ToolCommand]
    package let search: ((String) -> [ToolCommand])?
    package let openStandalone: (() -> Void)?
    package let shouldTerminate: (() -> NSApplication.TerminateReply)?

    package init(commands: @escaping () -> [ToolCommand],
                 search: ((String) -> [ToolCommand])? = nil,
                 openStandalone: (() -> Void)? = nil,
                 shouldTerminate: (() -> NSApplication.TerminateReply)? = nil) {
        self.commands = commands
        self.search = search
        self.openStandalone = openStandalone
        self.shouldTerminate = shouldTerminate
    }
}
