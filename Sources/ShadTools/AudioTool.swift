import AppKit
import CoreAudio
import CryptoKit

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

enum AudioPinPolicy {
    static func target(uid: String?, route: AudioRoute, current: AudioDeviceID?, devices: [RouteDevice]) -> RouteDevice? {
        guard let uid,
              let candidate = devices.first(where: { $0.uid == uid && $0.routes.contains(route) }),
              candidate.id != current else { return nil }
        return candidate
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
final class AudioTool {
    private let core: AudioRouting
    // The suite and standalone need the same pins when both are running.
    private let defaults: UserDefaults
    private static let preferenceEvent = Notification.Name("io.github.syedshad.ShadTools.audio.pinChanged")
    private var listener: AudioListener?
    private var preferenceObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private var devices: [RouteDevice] = []
    private var current: [AudioRoute: AudioDeviceID] = [:]
    private var retryCount: [AudioRoute: Int] = [:]
    private var errors: [AudioRoute: OSStatus] = [:]
    private var retries: Task<Void, Never>?

    convenience init() {
        self.init(core: CoreAudioRoutes(), defaults: UserDefaults(suiteName: "io.github.syedshad.ShadTools.audio")!)
        listener = AudioListener { [weak self] in self?.scheduleRefresh() }
        preferenceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.preferenceEvent, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleRefresh() } }
        scheduleRefresh()
    }

    init(core: AudioRouting, defaults: UserDefaults) {
        self.core = core
        self.defaults = defaults
        synchronizeDevices()
    }

    deinit {
        if let preferenceObserver { DistributedNotificationCenter.default().removeObserver(preferenceObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        pendingRefresh?.cancel()
        retries?.cancel()
    }

    private func preference(_ route: AudioRoute) -> [String: String]? {
        defaults.dictionary(forKey: route.rawValue) as? [String: String]
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled, let self else { return }
            self.synchronizeDevices()
            Commands.changed()
        }
    }

    func synchronizeDevices() {
        defaults.synchronize()
        devices = core.devices()
        var needsRetry = false
        for route in AudioRoute.allCases {
            current[route] = core.current(route)
            guard let target = AudioPinPolicy.target(uid: preference(route)?["uid"], route: route,
                                                     current: current[route], devices: devices) else {
                retryCount[route] = nil
                errors[route] = nil
                continue
            }
            let status = core.set(target.id, for: route)
            if status == noErr {
                current[route] = core.current(route)
                errors[route] = nil
            } else {
                errors[route] = status
            }
            if current[route] != target.id, retryCount[route, default: 0] < 3 {
                retryCount[route, default: 0] += 1
                needsRetry = true
            }
        }
        if needsRetry {
            retries?.cancel()
            retries = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                self?.synchronizeDevices()
                Commands.changed()
            }
        }
    }

    private func save(_ device: RouteDevice?, for route: AudioRoute) {
        if let device {
            guard let live = core.devices().first(where: { $0.uid == device.uid && $0.routes.contains(route) }) else {
                Feedback.show("\(device.name) is disconnected")
                return
            }
            let status = core.set(live.id, for: route)
            guard status == noErr else {
                Feedback.show("Couldn’t select \(device.name) · Core Audio error \(status)")
                return
            }
            defaults.set(["uid": live.uid, "name": live.name], forKey: route.rawValue)
            Feedback.show("Pinned \(route.rawValue) to \(live.name)")
        } else {
            defaults.removeObject(forKey: route.rawValue)
            Feedback.show("Automatic \(route.rawValue) switching enabled")
        }
        defaults.synchronize()
        retryCount[route] = nil
        DistributedNotificationCenter.default().postNotificationName(Self.preferenceEvent, object: nil, userInfo: nil, deliverImmediately: true)
        scheduleRefresh()
    }

    func commands() -> [ToolCommand] {
        var result: [ToolCommand] = []
        for route in AudioRoute.allCases {
            let saved = preference(route)
            let label = route.rawValue.capitalized
            for device in devices where device.routes.contains(route) {
                let pinned = saved?["uid"] == device.uid
                let active = current[route] == device.id
                var detail = pinned ? "Pinned \(route.rawValue)" : "Keep this \(route.rawValue) when devices connect"
                if active { detail += " · Current default" }
                if pinned, let error = errors[route] { detail = "Couldn’t restore · Core Audio error \(error)" }
                let suffix = SHA256.hash(data: Data(device.uid.utf8)).map { String(format: "%02x", $0) }.joined()
                result.append(ToolCommand(id: "audio.pin.\(route.rawValue).\(suffix)", title: "Pin \(label) to \(device.name)",
                                          subtitle: detail, symbol: pinned ? "pin.fill" : route.symbol, group: "Audio",
                                          keywords: "default sound microphone headphones speakers lock device") { [weak self] in
                    self?.save(device, for: route)
                })
            }
            if let saved {
                let connected = devices.contains { $0.uid == saved["uid"] && $0.routes.contains(route) }
                var detail = saved["name"] ?? label
                if !connected { detail += " · Reconnect to restore" }
                result.append(ToolCommand(id: "audio.unpin.\(route.rawValue)", title: "Unpin Audio \(label)",
                                          subtitle: detail, symbol: "pin.slash", group: "Audio",
                                          keywords: "automatic default sound unlock") { [weak self] in
                    self?.save(nil, for: route)
                })
            }
        }
        if result.isEmpty {
            result.append(ToolCommand(id: "audio.refresh", title: "Refresh Audio Devices", subtitle: "Check for available inputs and outputs",
                                      symbol: "arrow.clockwise", group: "Audio", keywords: "microphone speakers headphones") { [weak self] in
                self?.scheduleRefresh()
            })
        }
        return result
    }
}
