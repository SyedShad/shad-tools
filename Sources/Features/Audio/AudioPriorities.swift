import CoreAudio
import Foundation

struct RankedAudioDevice: Equatable, Codable, Identifiable {
    let uid: String
    var name: String
    var id: String { uid }
}

struct AudioPriorityList: Equatable, Codable {
    var enabled = true
    var devices: [RankedAudioDevice] = []

    // New devices join at the bottom. Once recorded, a UID keeps its place offline.
    mutating func discover(_ connected: [RouteDevice], route: AudioRoute, initialDefault: AudioDeviceID?) {
        var available = connected.filter { $0.routes.contains(route) }
        if let index = available.firstIndex(where: { $0.id == initialDefault }) {
            available.insert(available.remove(at: index), at: 0)
        }
        for device in available {
            if let index = devices.firstIndex(where: { $0.uid == device.uid }) {
                devices[index].name = device.name
            } else {
                devices.append(RankedAudioDevice(uid: device.uid, name: device.name))
            }
        }
    }

    func winner(for route: AudioRoute, among available: [RouteDevice]) -> RouteDevice? {
        guard enabled else { return nil }
        for entry in devices {
            if let device = available.first(where: { $0.uid == entry.uid && $0.routes.contains(route) }) {
                return device
            }
        }
        return nil
    }

    mutating func move(_ uid: String, to index: Int) {
        guard let old = devices.firstIndex(where: { $0.uid == uid }),
              devices.indices.contains(index) else { return }
        devices.insert(devices.remove(at: old), at: index)
    }
}

@MainActor final class AudioPriorityStore {
    private let defaults: UserDefaults
    private let lockFile: URL?
    private var encoder = JSONEncoder()
    private var decoder = JSONDecoder()

    init(defaults: UserDefaults, lockFile: URL? = nil) {
        self.defaults = defaults
        self.lockFile = lockFile
    }

    // Serialize discovery and user edits from the suite and standalone app. Each
    // operation reads the last committed order before applying its own change.
    func update(_ route: AudioRoute, _ edit: (inout AudioPriorityList) -> Void) -> AudioPriorityList {
        var fd: Int32 = -1
        if let lockFile {
            fd = open(lockFile.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if fd != -1 {
                while flock(fd, LOCK_EX) == -1 && errno == EINTR {}
            }
        }
        defer { if fd != -1 { flock(fd, LOCK_UN); close(fd) } }
        defaults.synchronize()
        let key = "audio.priorities.v1." + route.rawValue
        let existing = defaults.data(forKey: key).flatMap { try? decoder.decode(AudioPriorityList.self, from: $0) }
        var list = existing ?? AudioPriorityList()
        if existing == nil, let pin = defaults.dictionary(forKey: route.rawValue) as? [String: String],
           let uid = pin["uid"] {
            list.devices.append(RankedAudioDevice(uid: uid, name: pin["name"] ?? uid))
        }
        edit(&list)
        if existing != list, let data = try? encoder.encode(list) {
            defaults.set(data, forKey: key)
            // Keep an older standalone edition from enforcing a superseded pin.
            if list.enabled, let first = list.devices.first {
                defaults.set(["uid": first.uid, "name": first.name], forKey: route.rawValue)
            } else {
                defaults.removeObject(forKey: route.rawValue)
            }
            defaults.synchronize()
        }
        return list
    }
}
