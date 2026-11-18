import AppKit
import ShadCore
import Carbon.HIToolbox

package enum CaptureModule {
    package static let definition: FeatureModule = {
        let modifiers = controlKey | optionKey | cmdKey
        return FeatureModule(
            id: "capture",
            appName: "Shad Capture",
            category: "Screen Capture",
            group: "Capture",
            detail: "Take screenshots and record your screen with a camera overlay",
            symbol: "camera.viewfinder",
            tileColor: NSColor(srgbRed: 0.94, green: 0.29, blue: 0.34, alpha: 1),
            homeTabTarget: true,
            launcher: KeyChord(35, modifiers, "P")
        ) {
            let tool = CaptureTool()
            return FeatureSession(commands: tool.commands,
                           shouldTerminate: { CameraRecorderWindow.shared.applicationShouldTerminate() })
        }
    }()
}
