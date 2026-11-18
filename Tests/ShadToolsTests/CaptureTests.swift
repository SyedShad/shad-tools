import Foundation
import Testing
@testable import ShadTools

@Suite("Capture commands and native engine routing")
struct CaptureTests {
    @Test func captureActionsMatchMacShotPublicRoutes() {
        let expected: Set<String> = [
            "capture", "capture-fullscreen", "capture-last", "quick-capture", "scroll-capture",
            "ocr", "ocr-translate", "record", "record-fullscreen", "stop-recording", "history", "settings"
        ]
        #expect(Set(CaptureAction.allCases.map(\.rawValue)) == expected)
        for action in CaptureAction.allCases {
            #expect(action.url.scheme == "macshot")
            #expect(action.url.host == action.rawValue)
        }
    }

    @Test func captureFallsBackToItsPackagedHelperOnCleanMachines() throws {
        let outer = URL(fileURLWithPath: "/Applications/Shad Capture.app", isDirectory: true)
        let bundled = CaptureEngine.embedded(in: outer)
        #expect(bundled.path == "/Applications/Shad Capture.app/Contents/Helpers/macshot.app")
        #expect(try CaptureEngine.destination(embedded: bundled, running: []) == bundled)
        #expect(throws: CaptureEngineError.self) { try CaptureEngine.destination(embedded: nil, running: []) }
    }

    @Test func compatibleRunningHelperReceivesActionsAcrossEditions() throws {
        let local = URL(fileURLWithPath: "/Applications/macshot.app")
        let bundled = CaptureEngine.embedded(in: URL(fileURLWithPath: "/Applications/Shad Tools.app"))
        for version in ["4.4.0", "4.10.0"] {
            let compatible = CaptureEngine.RunningCopy(url: local, version: version, trusted: true)
            #expect(try CaptureEngine.destination(embedded: bundled, running: [compatible]) == local)
        }
        for incompatible in [CaptureEngine.RunningCopy(url: local, version: "4.3.0", trusted: true),
                             CaptureEngine.RunningCopy(url: local, version: "4.9.0", trusted: false)] {
            #expect(throws: CaptureEngineError.self) { try CaptureEngine.destination(embedded: bundled, running: [incompatible]) }
        }
    }

    @Test @MainActor func capturePaletteHasAllEntryPointsAndPersistentUniqueIDs() {
        let tool = CaptureTool()
        let rows = tool.commands()
        let ids = Set(rows.map(\.id))
        #expect(ids.count == rows.count)
        #expect(rows.allSatisfy { $0.group == "Capture" })
        #expect(ids == Set(CaptureAction.allCases.map { "capture." + $0.rawValue }).union(
            ["capture.presenter", "capture.edit-image", "capture.edit-video", "capture.tools"]))
    }
}
