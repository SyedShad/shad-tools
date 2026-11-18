import ShadCore
import AppKit
import Carbon.HIToolbox
import Foundation

struct MouseAction: Equatable, Codable {
    var title: String
    var shortcut: KeyChord
    var symbol: String

    init(title: String, shortcut: KeyChord, symbol: String = "keyboard") {
        self.title = title
        self.shortcut = shortcut
        self.symbol = symbol
    }
}

struct MouseAppProfile: Equatable, Codable {
    var name: String
    var dial: [MouseAction]? = nil
    var gestures: [MouseDirection: MouseAction]? = nil
    var usesCustomGestures = false
}

struct MouseConfiguration: Equatable, Codable {
    var enabled = false
    var dialTrigger = MouseTrigger.middle
    var gestureTrigger = MouseTrigger.middle
    var gestureThreshold: Double = 30
    var global = MouseDefaults.global
    var fallback = MouseDefaults.fallback
    var gestures = MouseDefaults.gestures
    var apps: [String: MouseAppProfile] = [:]

    func appActions(for bundleID: String?) -> [MouseAction] {
        guard let bundleID else { return fallback }
        return apps[bundleID]?.dial ?? MouseDefaults.preset(for: bundleID) ?? fallback
    }

    func gesture(_ direction: MouseDirection, for bundleID: String?) -> MouseAction {
        if let bundleID, let app = apps[bundleID], app.usesCustomGestures, let action = app.gestures?[direction] { return action }
        return gestures[direction] ?? MouseDefaults.gesture(direction)
    }

    func validate() throws {
        let sides = [global, fallback] + apps.values.compactMap(\.dial)
        let sets = [gestures] + apps.values.compactMap(\.gestures)
        guard sides.allSatisfy({ $0.count == 4 }),
              sets.allSatisfy({ Set($0.keys) == Set(MouseDirection.allCases) }),
              dialTrigger.isUsable, gestureTrigger.isUsable,
              (12...100).contains(gestureThreshold) else { throw CocoaError(.coderReadCorrupt) }
    }
}

enum MouseDefaults {
    private static func action(_ title: String, _ symbol: String, _ code: Int, _ key: String, _ modifiers: Int = cmdKey) -> MouseAction {
        MouseAction(title: title, shortcut: KeyChord(code, modifiers, key), symbol: symbol)
    }

    static let global = [
        action("Copy", "doc.on.doc", 8, "C"), action("Paste", "doc.on.clipboard", 9, "V"),
        action("Undo", "arrow.uturn.backward", 6, "Z"), action("Redo", "arrow.uturn.forward", 6, "Z", cmdKey | shiftKey)
    ]
    static let fallback = [
        action("Find", "magnifyingglass", 3, "F"), action("New Window", "macwindow.badge.plus", 45, "N"),
        action("Save", "square.and.arrow.down", 1, "S"), action("Select All", "selection.pin.in.out", 0, "A")
    ]
    private static let browser = [
        action("New Tab", "plus.square.on.square", 17, "T"), action("Address Bar", "link", 37, "L"),
        action("Reopen Tab", "arrow.uturn.backward.square", 17, "T", cmdKey | shiftKey), action("Reload", "arrow.clockwise", 15, "R")
    ]
    private static let finder = [
        action("Quick Look", "eye", 49, "Space", 0), action("New Folder", "folder.badge.plus", 45, "N", cmdKey | shiftKey),
        action("Get Info", "info.circle", 34, "I"), action("Find Files", "magnifyingglass", 3, "F")
    ]
    private static let textEditor = [
        action("New Document", "doc.badge.plus", 45, "N"), action("Find", "magnifyingglass", 3, "F"),
        action("Bold", "bold", 11, "B"), action("Save", "square.and.arrow.down", 1, "S")
    ]

    static func preset(for id: String) -> [MouseAction]? {
        switch id.lowercased() {
        case "com.apple.finder": return finder
        case "com.apple.textedit": return textEditor
        case "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.canary",
             "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "com.microsoft.edgemac", "com.brave.browser",
             "com.vivaldi.vivaldi", "company.thebrowser.browser", "org.chromium.chromium": return browser
        default: return nil
        }
    }
    static func gesture(_ direction: MouseDirection) -> MouseAction {
        switch direction {
        case .up: return action("Go to Top", "arrow.up.to.line", 126, "↑")
        case .down: return action("Go to Bottom", "arrow.down.to.line", 125, "↓")
        case .left: return action("Go Back", "chevron.backward", 33, "[")
        case .right: return action("Go Forward", "chevron.forward", 30, "]")
        }
    }
    static let gestures = Dictionary(uniqueKeysWithValues: MouseDirection.allCases.map { ($0, gesture($0)) })
}

enum MouseSlot: Equatable {
    case universal(Int)
    case application(bundleID: String?, name: String, index: Int)
    case gesture(MouseDirection, bundleID: String?, name: String)
}

@MainActor final class MouseProfiles: ObservableObject {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Shad Tools/Mouse", isDirectory: true)
    private static let changed = Notification.Name("io.github.syedshad.shadtools.mouse.profilesChanged")
    private let directory: URL
    private let file: URL
    private let publishesChanges: Bool
    private var observer: NSObjectProtocol?
    @Published private(set) var configuration = MouseConfiguration()
    @Published private(set) var error: String?

    convenience init() { self.init(directory: Self.defaultDirectory, observe: true) }
    init(directory: URL, observe: Bool = false) {
        self.directory = directory
        file = directory.appendingPathComponent("profiles-v1.json")
        publishesChanges = observe
        if observe {
            observer = DistributedNotificationCenter.default().addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }
    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func read() throws -> MouseConfiguration {
        do {
            let result = try JSONDecoder().decode(MouseConfiguration.self, from: Data(contentsOf: file))
            try result.validate()
            return result
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return MouseConfiguration()
        }
    }

    func refresh() {
        do {
            let latest = try read()
            if latest != configuration { configuration = latest }
            error = nil
        } catch {
            self.error = "Mouse preferences could not be read. " + error.localizedDescription
        }
    }

    // Merge only the requested change against the most recent configuration under
    // a shared lock. Separate editions can edit different slots at the same time.
    private func edit(_ change: (inout MouseConfiguration) -> Void) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(directory.appendingPathComponent("profiles.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            while flock(fd, LOCK_EX) == -1 { if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) } }
            defer { flock(fd, LOCK_UN) }
            var latest = try read()
            change(&latest)
            try latest.validate()
            try JSONEncoder().encode(latest).write(to: file, options: .atomic)
            configuration = latest
            error = nil
            if publishesChanges { DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil, userInfo: nil, deliverImmediately: true) }
        } catch {
            self.error = "Mouse preferences could not be saved. " + error.localizedDescription
        }
    }

    func actions(for bundleID: String?) -> [MouseAction] {
        configuration.global + configuration.appActions(for: bundleID)
    }
    func gesture(_ direction: MouseDirection, for bundleID: String?) -> MouseAction {
        configuration.gesture(direction, for: bundleID)
    }
    func setEnabled(_ value: Bool) { edit { $0.enabled = value } }
    func setTrigger(_ value: MouseTrigger, forDial: Bool) {
        edit { if forDial { $0.dialTrigger = value } else { $0.gestureTrigger = value } }
    }
    func setThreshold(_ value: Double) { edit { $0.gestureThreshold = min(100, max(12, value)) } }

    func action(for slot: MouseSlot) -> MouseAction? {
        switch slot {
        case .universal(let index): return configuration.global.indices.contains(index) ? configuration.global[index] : nil
        case let .application(id, _, index):
            let actions = configuration.appActions(for: id)
            return actions.indices.contains(index) ? actions[index] : nil
        case let .gesture(direction, id, _): return gesture(direction, for: id)
        }
    }
    func assign(_ action: MouseAction, to slot: MouseSlot) {
        guard !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        edit { config in
            switch slot {
            case .universal(let index):
                if config.global.indices.contains(index) { config.global[index] = action }
            case let .application(id, name, index):
                var side = config.appActions(for: id)
                guard side.indices.contains(index) else { return }
                side[index] = action
                if let id { config.apps[id, default: MouseAppProfile(name: name)].dial = side }
                else { config.fallback = side }
            case let .gesture(direction, id, name):
                if let id {
                    var assignments = config.apps[id]?.gestures ?? config.gestures
                    assignments[direction] = action
                    config.apps[id, default: MouseAppProfile(name: name)].gestures = assignments
                    config.apps[id]?.usesCustomGestures = true
                } else { config.gestures[direction] = action }
            }
        }
    }
    func setAppGestures(_ enabled: Bool, bundleID: String, name: String) {
        edit { config in
            if enabled {
                if config.apps[bundleID]?.gestures == nil { config.apps[bundleID, default: MouseAppProfile(name: name)].gestures = config.gestures }
            }
            config.apps[bundleID]?.usesCustomGestures = enabled
        }
    }
}
