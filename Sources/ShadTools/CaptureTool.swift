import AppKit
import Security
import UniformTypeIdentifiers

/// URL actions supported by MacShot 4.4.0's AppDelegate. File opening uses the
/// document API, so user-selected filenames never become URL commands.
enum CaptureAction: String, CaseIterable {
    case area = "capture"
    case screen = "capture-fullscreen"
    case previous = "capture-last"
    case quick = "quick-capture"
    case scroll = "scroll-capture"
    case text = "ocr"
    case translate = "ocr-translate"
    case record = "record"
    case recordScreen = "record-fullscreen"
    case stop = "stop-recording"
    case history
    case settings

    var url: URL { URL(string: "macshot://" + rawValue)! }
    var metadata: (title: String, subtitle: String, icon: String, search: String) {
        switch self {
        case .area: return ("Capture Area or Window", "Select a region or click a window to annotate it", "viewfinder", "screenshot snip window snap markup annotate rectangle pencil arrow blur redact")
        case .screen: return ("Capture Full Screen", "Take a screenshot of the display", "display", "screenshot full display monitor")
        case .previous: return ("Capture Last Area", "Repeat your previous screenshot selection", "arrow.counterclockwise", "screenshot repeat region")
        case .quick: return ("Quick Capture", "Select an area and apply your configured copy or save action", "bolt", "screenshot fast clipboard")
        case .scroll: return ("Capture Scrolling Content", "Stitch a scrolling region into one image", "scroll", "screenshot webpage tall horizontal vertical")
        case .text: return ("Extract Text or QR Code", "Select text or a code to recognize", "text.viewfinder", "screenshot OCR scan barcode QR vision")
        case .translate: return ("Translate Text on Screen", "Select an area and overlay its translation", "character.bubble", "screenshot OCR translate language")
        case .record: return ("Record Screen Area", "Select a region, audio and recording options", "record.circle", "video MP4 GIF microphone recording Studio")
        case .recordScreen: return ("Record Full Screen", "Record the display with MacShot's recording controls", "rectangle.inset.filled.and.person.filled", "video movie microphone output system audio recording Studio")
        case .stop: return ("Stop Screen Recording", "Finish the current MacShot take", "stop.circle", "stop video record save")
        case .history: return ("Recent Captures", "Browse screenshots and reopen editable annotations", "clock.arrow.circlepath", "screenshot history pin edit past")
        case .settings: return ("Capture Settings", "Set hotkeys, formats, output, upload providers and editor behavior", "slider.horizontal.3", "screenshot recording MacShot preferences export S3 imgbb Google Drive")
        }
    }
}

enum CaptureEngineError: LocalizedError {
    case missing, incompatible, disabled

    var errorDescription: String? {
        switch self {
        case .missing: return "The capture engine is missing. Install Shad Capture or Shad Tools from its package."
        case .incompatible: return "Quit the other running copy of MacShot, then try again to use the bundled MacShot 4.4.0."
        case .disabled: return "Enable the macshot:// URL scheme in Capture Settings, then run the command again."
        }
    }
}

struct CaptureEngine {
    static let id = "com.sw33tlie.macshot.macshot"
    static let version = "4.4.0"
    static let requirement = "anchor apple generic and identifier \"com.sw33tlie.macshot.macshot\" and certificate leaf[subject.OU] = \"J4XGH8RFS8\""

    struct RunningCopy {
        let url: URL
        let version: String
        let trusted: Bool
    }

    static func embedded(in bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Helpers/macshot.app", isDirectory: true)
    }

    /// MacShot enforces one process per user. Deliver requests to an already
    /// running compatible copy, including the copy shipped by another Shad edition.
    static func destination(embedded: URL?, running: [RunningCopy]) throws -> URL {
        if let copy = running.first(where: { $0.trusted && $0.version.compare(version, options: .numeric) != .orderedAscending }) {
            return copy.url
        }
        if !running.isEmpty { throw CaptureEngineError.incompatible }
        guard let embedded else { throw CaptureEngineError.missing }
        return embedded
    }

    static func trustedProcess(_ pid: pid_t) -> Bool {
        var code: SecCode?
        var signer: SecRequirement?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &signer) == errSecSuccess, let signer else { return false }
        return SecCodeCheckValidity(code, [], signer) == errSecSuccess
    }

    static func runningCopies() -> [RunningCopy] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap { app in
            guard !app.isTerminated, let url = app.bundleURL else { return nil }
            let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            return RunningCopy(url: url, version: version, trusted: trustedProcess(app.processIdentifier))
        }
    }
}

@MainActor final class CaptureTool {
    func commands() -> [ToolCommand] {
        var commands = CaptureAction.allCases.map { action in
            let info = action.metadata
            return ToolCommand(id: "capture." + action.rawValue, title: info.title, subtitle: info.subtitle, symbol: info.icon,
                               group: "Capture", keywords: "MacShot " + info.search) {
                self.perform(action)
            }
        }
        commands.append(ToolCommand(id: "capture.presenter", title: "Record Screen with Camera",
                                    subtitle: "Choose a screen, window, camera overlay and microphone", symbol: "person.crop.rectangle",
                                    group: "Capture", keywords: "Loom presenter webcam front camera green screen chroma key shape size round square") {
            CameraRecorderWindow.shared.show()
        })
        if CameraRecorderWindow.shared.isRecording {
            commands.insert(ToolCommand(id: "capture.presenter.stop", title: "Stop and Save Camera Recording",
                                        subtitle: "Finish your presenter recording and write the MP4", symbol: "stop.circle.fill",
                                        group: "Capture", keywords: "Loom presenter webcam stop camera screen recording save") {
                CameraRecorderWindow.shared.stop()
            }, at: 0)
        }
        commands.append(ToolCommand(id: "capture.edit-image", title: "Open Image in Capture Editor",
                                    subtitle: "Annotate, redact, crop or beautify an image file", symbol: "pencil.and.outline",
                                    group: "Capture", keywords: "screenshot mark up effects shadow gradient annotate blur background") {
            self.chooseFile(movie: false)
        })
        commands.append(ToolCommand(id: "capture.edit-video", title: "Open Video in Studio",
                                    subtitle: "Edit the timeline, pointer, zoom, captions and camera tracks", symbol: "film",
                                    group: "Capture", keywords: "MacShot movie editor video trim cut export MP4 recording") {
            self.chooseFile(movie: true)
        })
        commands.append(ToolCommand(id: "capture.tools", title: "Open MacShot",
                                    subtitle: "Access the capture delay, Record GIF, clipboard and other menu bar tools", symbol: "menubar.rectangle",
                                    group: "Capture", keywords: "screenshot delayed timer GIF clipboard pin recordings settings menu") {
            self.open(url: nil)
        })
        return commands
    }

    private func perform(_ action: CaptureAction) {
        if action == .stop, NSRunningApplication.runningApplications(withBundleIdentifier: CaptureEngine.id).isEmpty {
            Feedback.show("No MacShot recording is running")
            return
        }
        if (UserDefaults.standard.persistentDomain(forName: CaptureEngine.id)?["urlSchemeEnabled"] as? Bool) == false {
            if action == .settings { open(url: nil) }
            else { Feedback.show(CaptureEngineError.disabled.localizedDescription) }
            return
        }
        open(url: action.url)
    }

    private func chooseFile(movie: Bool) {
        let panel = NSOpenPanel()
        panel.title = movie ? "Open Video in Studio" : "Open Image in Capture Editor"
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extensions = movie ? ["mp4", "mov", "m4v"] : ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp", "icns"]
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            self.open(url: url)
        }
    }

    private func open(url: URL?) {
        let bundled = CaptureEngine.embedded(in: Bundle.main.bundleURL)
        let exists = Bundle(url: bundled)?.bundleIdentifier == CaptureEngine.id
        let running = CaptureEngine.runningCopies()
        do {
            let target = try CaptureEngine.destination(embedded: exists ? bundled : nil, running: running)
            let configuration = NSWorkspace.OpenConfiguration()
            // Sparkle in the helper shares the host's signed bundle. A new Shad installer
            // updates that bundle. These arguments only affect this launch, not user defaults.
            if running.isEmpty {
                configuration.arguments = ["-SUEnableAutomaticChecks", "NO", "-SUAutomaticallyUpdate", "NO"]
            }
            if let url {
                NSWorkspace.shared.open([url], withApplicationAt: target, configuration: configuration) { _, error in
                    if let error { Task { @MainActor in Feedback.show("Couldn’t open MacShot · " + error.localizedDescription) } }
                }
            } else {
                NSWorkspace.shared.openApplication(at: target, configuration: configuration) { _, error in
                    Task { @MainActor in
                        if let error { Feedback.show("Couldn’t open MacShot · " + error.localizedDescription) }
                        else {
                            // The native reopen observer reveals a hidden menu icon and Settings,
                            // including when URL control is disabled in MacShot.
                            DistributedNotificationCenter.default().postNotificationName(.init("com.sw33tlie.macshot.showAndOpenPrefs"),
                                object: nil, userInfo: nil, deliverImmediately: true)
                            Feedback.show("Open MacShot’s menu bar icon for all capture tools")
                        }
                    }
                }
            }
        } catch { Feedback.show(error.localizedDescription) }
    }
}
