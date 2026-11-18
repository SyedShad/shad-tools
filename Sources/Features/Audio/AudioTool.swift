import ShadCore
import AppKit
import CoreAudio
import CryptoKit
import SwiftUI

enum AudioRoute: String, CaseIterable {
    case input, output

    var selector: AudioObjectPropertySelector {
        self == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var symbol: String { self == .input ? "mic" : "speaker.wave.2" }
}

struct RouteDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let routes: Set<AudioRoute>
}

private func audioAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

protocol AudioRouting {
    func devices() -> [RouteDevice]
    func current(_ route: AudioRoute) -> AudioDeviceID?
    func set(_ id: AudioDeviceID, for route: AudioRoute) -> OSStatus
}

struct CoreAudioRoutes: AudioRouting {
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func devices() -> [RouteDevice] {
        var address = audioAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride).compactMap { id in
            guard readNumber(id, audioAddress(kAudioDevicePropertyDeviceIsAlive)) == 1,
                  let uid = readString(id, kAudioDevicePropertyDeviceUID),
                  let name = readString(id, kAudioObjectPropertyName) else { return nil }
            let available = Set(AudioRoute.allCases.filter {
                readNumber(id, audioAddress(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: $0.scope)) == 1
            })
            return available.isEmpty ? nil : RouteDevice(id: id, uid: uid, name: name, routes: available)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func current(_ route: AudioRoute) -> AudioDeviceID? {
        readNumber(system, audioAddress(route.selector))
    }

    func set(_ id: AudioDeviceID, for route: AudioRoute) -> OSStatus {
        var address = audioAddress(route.selector)
        var device = id
        return AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: device)), &device)
    }

    private func readNumber(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress) -> UInt32? {
        var address = property
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = audioAddress(selector)
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: reference))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &reference) == noErr else { return nil }
        return reference?.takeRetainedValue() as String?
    }
}

private final class AudioListener {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private let block: AudioObjectPropertyListenerBlock
    private var properties: [AudioObjectPropertySelector] = []

    init(changed: @escaping @MainActor () -> Void) {
        block = { _, _ in Task { @MainActor in changed() } }
        for selector in [kAudioHardwarePropertyDevices, AudioRoute.input.selector, AudioRoute.output.selector] {
            var address = audioAddress(selector)
            if AudioObjectAddPropertyListenerBlock(system, &address, .main, block) == noErr {
                properties.append(selector)
            }
        }
    }

    deinit {
        for selector in properties {
            var address = audioAddress(selector)
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, block)
        }
    }
}

@MainActor
final class AudioTool: ObservableObject {
    private let core: AudioRouting
    private let store: AudioPriorityStore
    private static let preferenceEvent = Notification.Name("io.github.syedshad.ShadTools.audio.pinChanged")
    private var listener: AudioListener?
    private var preferenceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private var retries: Task<Void, Never>?
    private var attempts = 0
    private var window: NSWindow?

    @Published var editorRoute: AudioRoute = .input
    @Published private(set) var devices: [RouteDevice] = []
    @Published private(set) var current: [AudioRoute: AudioDeviceID] = [:]
    @Published private(set) var lists: [AudioRoute: AudioPriorityList] = [:]
    @Published private(set) var errors: [AudioRoute: String] = [:]

    convenience init() {
        let shared = "io.github.syedshad.ShadTools.audio"
        let lock = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/" + shared + ".lock")
        self.init(core: CoreAudioRoutes(), defaults: UserDefaults(suiteName: shared)!, lockFile: lock)
        listener = AudioListener { [weak self] in self?.scheduleRefresh() }
        preferenceObserver = DistributedNotificationCenter.default().addObserver(forName: Self.preferenceEvent, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.scheduleRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in self?.scheduleRefresh() }
        }
        scheduleRefresh()
    }

    init(core: AudioRouting, defaults: UserDefaults, lockFile: URL? = nil) {
        self.core = core
        store = AudioPriorityStore(defaults: defaults, lockFile: lockFile)
        synchronizeDevices()
    }

    deinit {
        if let preferenceObserver { DistributedNotificationCenter.default().removeObserver(preferenceObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pendingRefresh?.cancel()
        retries?.cancel()
    }

    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled, let self else { return }
            pendingRefresh = nil
            synchronizeDevices()
            Commands.changed()
        }
    }

    func synchronizeDevices() {
        let live = core.devices()
        var active: [AudioRoute: AudioDeviceID] = [:]
        var latest: [AudioRoute: AudioPriorityList] = [:]
        var problems: [AudioRoute: String] = [:]
        for route in AudioRoute.allCases {
            let selected = core.current(route)
            active[route] = selected
            let list = store.update(route) { $0.discover(live, route: route, initialDefault: selected) }
            latest[route] = list
            guard let target = list.winner(for: route, among: live), target.id != selected else { continue }
            let status = core.set(target.id, for: route)
            active[route] = core.current(route)
            if active[route] != target.id {
                problems[route] = status == noErr ? "Waiting for " + target.name : "Couldn’t select " + target.name + " (Core Audio " + String(status) + ")"
            }
        }
        if devices != live { devices = live }
        if lists != latest { lists = latest }
        if current != active { current = active }
        if errors != problems { errors = problems }
        if problems.isEmpty {
            retries?.cancel()
            retries = nil
            attempts = 0
        } else if retries == nil {
            let delay = UInt64(300_000_000) << min(attempts, 4)
            attempts = min(attempts + 1, 4)
            retries = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self else { return }
                retries = nil
                synchronizeDevices()
                Commands.changed()
            }
        }
    }

    private func edit(_ route: AudioRoute, _ transform: (inout AudioPriorityList) -> Void) {
        _ = store.update(route, transform)
        synchronizeDevices()
        DistributedNotificationCenter.default().postNotificationName(Self.preferenceEvent, object: nil, userInfo: nil, deliverImmediately: true)
        Commands.changed()
    }

    func move(_ uid: String, in route: AudioRoute, by offset: Int) {
        edit(route) { list in
            if let index = list.devices.firstIndex(where: { $0.uid == uid }) {
                list.move(uid, to: index + offset)
            }
        }
    }

    func promote(_ uid: String, in route: AudioRoute) {
        edit(route) {
            $0.move(uid, to: 0)
            $0.enabled = true
        }
    }

    func setEnabled(_ enabled: Bool, for route: AudioRoute) {
        edit(route) { $0.enabled = enabled }
    }

    func forget(_ uid: String, in route: AudioRoute) {
        guard !core.devices().contains(where: { $0.uid == uid && $0.routes.contains(route) }) else { return }
        edit(route) { $0.devices.removeAll { $0.uid == uid } }
    }

    private func showList(_ route: AudioRoute) {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 538, height: 416),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = "Audio Priorities"
            panel.minSize = NSSize(width: 430, height: 300)
            panel.isReleasedWhenClosed = false
            panel.center()
            window = panel
        }
        editorRoute = route
        window?.contentView = NSHostingView(rootView: AudioPriorityEditor(tool: self))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func commands() -> [ToolCommand] {
        var commands: [ToolCommand] = []
        for route in AudioRoute.allCases {
            let direction = route.rawValue.capitalized
            let list = lists[route] ?? AudioPriorityList()
            let winner = list.winner(for: route, among: devices)
            commands.append(ToolCommand(id: "audio.manage." + route.rawValue, title: "Manage " + direction + " Priorities",
                                        subtitle: list.enabled ? (winner?.name ?? "Waiting for a connected device") : "macOS automatic routing",
                                        symbol: "list.number", group: "Audio", keywords: "rank hierarchy reorder priority microphone headphones speakers default") { [weak self] in
                self?.showList(route)
            })
            for (index, entry) in list.devices.enumerated() {
                let stableID = SHA256.hash(data: Data(entry.uid.utf8)).map { String(format: "%02x", $0) }.joined()
                let active = devices.first { $0.uid == entry.uid && $0.routes.contains(route) }
                let status = active == nil ? "Disconnected" : current[route] == active?.id ? "Current default" : "Connected"
                commands.append(ToolCommand(id: "audio.pin." + route.rawValue + "." + stableID,
                                            title: "Make " + entry.name + " First for " + direction,
                                            subtitle: "Priority " + String(index + 1) + " · " + status, symbol: route.symbol, group: "Audio",
                                            keywords: "pin default sound microphone headphones speakers lock hierarchy priority") { [weak self] in
                    self?.promote(entry.uid, in: route)
                    Feedback.show(entry.name + " is first for " + route.rawValue)
                })
            }
            let toggleTitle = list.enabled ? "Use macOS Automatic " + direction : "Use " + direction + " Priorities"
            let toggleID = list.enabled ? "audio.unpin." : "audio.enable."
            commands.append(ToolCommand(id: toggleID + route.rawValue, title: toggleTitle,
                                        subtitle: list.enabled ? "Pause this priority list" : "Use the highest-ranked connected device",
                                        symbol: "arrow.triangle.2.circlepath", group: "Audio", keywords: "automatic unpin pause restore hierarchy") { [weak self] in
                self?.setEnabled(!list.enabled, for: route)
                Feedback.show(toggleTitle)
            })
        }
        return commands
    }
}
