import CoreAudio
import Foundation
import Testing
@testable import ShadTools

private final class SimulatedAudio: AudioRouting {
    var connected: [RouteDevice]
    var routes: [AudioRoute: AudioDeviceID]
    var writes: [AudioRoute] = []
    var failNextSet = false

    init(devices: [RouteDevice], input: AudioDeviceID, output: AudioDeviceID) {
        connected = devices
        routes = [.input: input, .output: output]
    }
    func devices() -> [RouteDevice] { connected }
    func current(_ route: AudioRoute) -> AudioDeviceID? { routes[route] }
    func set(_ id: AudioDeviceID, for route: AudioRoute) -> OSStatus {
        writes.append(route)
        if failNextSet { failNextSet = false; return -1 }
        routes[route] = id
        return noErr
    }
}

@MainActor struct AudioTests {
    let mic = RouteDevice(id: 4, uid: "internal-mic", name: "Built-in Mic", routes: [.input])
    let speaker = RouteDevice(id: 5, uid: "speakers", name: "Speakers", routes: [.output])
    let headset = RouteDevice(id: 21, uid: "headset", name: "Headphones", routes: [.input, .output])
    let desk = RouteDevice(id: 23, uid: "desk-mic", name: "Desk Mic", routes: [.input])

    private func withDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let domain = "io.github.shadtools.tests.audio." + UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: domain))
        defer { prefs.removePersistentDomain(forName: domain) }
        try test(prefs)
    }

    @Test func openingKeepsDefaultsAndNewHeadsetCannotTakeOver() throws {
        try withDefaults { prefs in
            let audio = SimulatedAudio(devices: [mic, speaker], input: mic.id, output: speaker.id)
            let tool = AudioTool(core: audio, defaults: prefs)
            #expect(audio.writes.isEmpty)
            audio.connected = [headset, mic, speaker]
            audio.routes = [.input: headset.id, .output: headset.id]
            tool.synchronizeDevices()
            #expect(tool.lists[.input]?.devices.map(\.uid) == [mic.uid, headset.uid])
            #expect(tool.lists[.output]?.devices.map(\.uid) == [speaker.uid, headset.uid])
            #expect(audio.routes == [.input: mic.id, .output: speaker.id])
            tool.promote(headset.uid, in: .output)
            #expect(audio.routes == [.input: mic.id, .output: headset.id])
            audio.writes = []
            tool.synchronizeDevices()
            #expect(audio.writes.isEmpty)
        }
    }

    @Test func restoresHighestConnectedRankAfterDisconnectManualChangeAndRelaunch() throws {
        try withDefaults { prefs in
            let audio = SimulatedAudio(devices: [headset, desk, mic, speaker], input: mic.id, output: headset.id)
            var tool: AudioTool? = AudioTool(core: audio, defaults: prefs)
            tool?.move(desk.uid, in: .input, by: -1)
            #expect(tool?.lists[.input]?.devices.map(\.uid) == [mic.uid, desk.uid, headset.uid])
            audio.connected.removeAll { $0.uid == mic.uid }
            audio.routes[.input] = headset.id
            tool?.synchronizeDevices()
            #expect(audio.routes[.input] == desk.id)
            tool = nil
            let relaunched = AudioTool(core: audio, defaults: prefs)
            #expect(relaunched.lists[.input]?.devices.first?.uid == mic.uid)
            let renamed = RouteDevice(id: 99, uid: mic.uid, name: "New mic name", routes: [.input])
            audio.connected.append(renamed)
            relaunched.synchronizeDevices()
            #expect(audio.routes[.input] == renamed.id)
            #expect(relaunched.lists[.input]?.devices.first?.name == renamed.name)
            audio.routes[.input] = desk.id
            relaunched.synchronizeDevices()
            #expect(audio.routes[.input] == renamed.id)
            #expect(audio.routes[.output] == headset.id)
        }
    }

    @Test func migratingDisconnectedPinAndIgnoringLookalikeAndWrongDirection() throws {
        try withDefaults { prefs in
            prefs.set(["uid": headset.uid, "name": headset.name], forKey: "input")
            let fake = RouteDevice(id: 41, uid: "other-headset", name: headset.name, routes: [.input])
            let outputOnly = RouteDevice(id: 42, uid: headset.uid, name: "Media mode", routes: [.output])
            let audio = SimulatedAudio(devices: [fake, mic, outputOnly], input: mic.id, output: outputOnly.id)
            let tool = AudioTool(core: audio, defaults: prefs)
            #expect(tool.lists[.input]?.devices.map(\.uid) == [headset.uid, mic.uid, fake.uid])
            #expect(audio.writes.isEmpty)
            audio.connected = [mic, fake, headset]
            tool.synchronizeDevices()
            #expect(audio.routes[.input] == headset.id)
        }
    }

    @Test func disablingOneListPreservesRanksAndReenableRestoresWinner() throws {
        try withDefaults { prefs in
            let audio = SimulatedAudio(devices: [mic, headset], input: mic.id, output: headset.id)
            let tool = AudioTool(core: audio, defaults: prefs)
            try #require(tool.commands().first { $0.id == "audio.unpin.input" }).perform()
            audio.routes[.input] = headset.id
            let relaunched = AudioTool(core: audio, defaults: prefs)
            #expect(audio.routes[.input] == headset.id)
            #expect(relaunched.lists[.input]?.enabled == false)
            #expect(relaunched.lists[.output]?.enabled == true)
            try #require(relaunched.commands().first { $0.id == "audio.enable.input" }).perform()
            #expect(audio.routes[.input] == mic.id)
        }
    }

    @Test func standaloneAndSuiteMergeLatestReorderAndDiscovery() throws {
        try withDefaults { prefs in
            let audio = SimulatedAudio(devices: [mic, headset, desk], input: mic.id, output: headset.id)
            let one = AudioTool(core: audio, defaults: prefs)
            let two = AudioTool(core: audio, defaults: prefs)
            one.promote(desk.uid, in: .input)
            two.move(headset.uid, in: .input, by: -1)
            one.synchronizeDevices()
            #expect(one.lists[.input]?.devices.map(\.uid) == [desk.uid, headset.uid, mic.uid])
            audio.connected.removeAll { $0.uid == desk.uid }
            one.forget(desk.uid, in: .input)
            two.synchronizeDevices()
            #expect(two.lists[.input]?.devices.map(\.uid) == [headset.uid, mic.uid])
            #expect(audio.routes[.input] == headset.id)
        }
    }

    @Test func transientWriteFailurePreservesRankUntilReconciliationSucceeds() throws {
        try withDefaults { prefs in
            let audio = SimulatedAudio(devices: [mic, headset], input: mic.id, output: headset.id)
            let tool = AudioTool(core: audio, defaults: prefs)
            audio.routes[.input] = headset.id
            audio.failNextSet = true
            tool.synchronizeDevices()
            #expect(tool.errors[.input] != nil)
            tool.synchronizeDevices()
            #expect(audio.routes[.input] == mic.id)
            #expect(tool.errors.isEmpty)
        }
    }
}
