import CoreAudio
import Foundation
import Testing
@testable import ShadTools

struct AudioTests {
    let builtIn = RouteDevice(id: 4, uid: "internal-mic", name: "Built-in", routes: [.input])
    let headset = RouteDevice(id: 21, uid: "headset", name: "Headphones", routes: [.input, .output])

    @Test func reconnectRestoresOnlyThePinnedDirection() {
        let routes = [builtIn, headset]
        #expect(AudioPinPolicy.target(uid: builtIn.uid, route: .input, current: headset.id, devices: routes) == builtIn)
        #expect(AudioPinPolicy.target(uid: nil, route: .output, current: headset.id, devices: routes) == nil)
        #expect(AudioPinPolicy.target(uid: builtIn.uid, route: .output, current: headset.id, devices: routes) == nil)
        #expect(AudioPinPolicy.target(uid: builtIn.uid, route: .input, current: builtIn.id, devices: routes) == nil)
    }

    @Test func missingPinWaitsForItsPersistentUID() {
        #expect(AudioPinPolicy.target(uid: headset.uid, route: .output, current: nil, devices: [builtIn]) == nil)
        let returned = RouteDevice(id: 56, uid: headset.uid, name: "New label", routes: [.output])
        #expect(AudioPinPolicy.target(uid: headset.uid, route: .output, current: 19, devices: [returned]) == returned)
    }

    @Test func sameNameWithDifferentUIDDoesNotCaptureMicrophone() {
        let other = RouteDevice(id: 9, uid: "another-mic", name: builtIn.name, routes: [.input])
        #expect(AudioPinPolicy.target(uid: builtIn.uid, route: .input, current: nil, devices: [other]) == nil)
    }
}


private final class SimulatedAudio: AudioRouting {
    var connected: [RouteDevice]
    var routes: [AudioRoute: AudioDeviceID]
    var writes: [AudioRoute] = []

    init(devices: [RouteDevice], routes: [AudioRoute: AudioDeviceID]) {
        self.connected = devices
        self.routes = routes
    }

    func devices() -> [RouteDevice] { connected }
    func current(_ route: AudioRoute) -> AudioDeviceID? { routes[route] }
    func set(_ id: AudioDeviceID, for route: AudioRoute) -> OSStatus {
        writes.append(route)
        routes[route] = id
        return noErr
    }
}

extension AudioTests {
    @Test @MainActor func pinCommandPersistsAcrossDisconnectReconnectAndRelaunch() throws {
        let domain = "io.github.shadtools.tests.audio." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let audio = SimulatedAudio(devices: [builtIn, headset], routes: [.input: headset.id, .output: headset.id])
        var tool: AudioTool? = AudioTool(core: audio, defaults: defaults)
        let pin = try #require(tool?.commands().first { $0.title == "Pin Input to Built-in" })
        pin.perform()
        #expect(audio.routes[.input] == builtIn.id)
        tool = nil

        // The user relaunches while their pinned mic is unplugged.
        audio.connected = [headset]
        audio.routes[.input] = headset.id
        audio.writes = []
        let relaunched = AudioTool(core: audio, defaults: defaults)
        #expect(audio.writes.isEmpty)
        #expect(relaunched.commands().contains { $0.id == "audio.unpin.input" && $0.subtitle.contains("Reconnect") })

        let returned = RouteDevice(id: 52, uid: builtIn.uid, name: "Studio Mic", routes: [.input])
        audio.connected.append(returned)
        relaunched.synchronizeDevices()
        #expect(audio.routes[.input] == returned.id)
        #expect(audio.routes[.output] == headset.id)
        #expect(audio.writes == [.input])

        let unpin = try #require(relaunched.commands().first { $0.id == "audio.unpin.input" })
        unpin.perform()
        audio.routes[.input] = headset.id
        relaunched.synchronizeDevices()
        #expect(audio.routes[.input] == headset.id)
        #expect(audio.writes == [.input])
    }
}
