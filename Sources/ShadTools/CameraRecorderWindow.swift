import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// Record which file the user agreed to replace. A long recording must not overwrite
// a different file created or edited at the same destination while capture was running.
struct CameraDestination {
    private struct Revision: Equatable {
        let identity: UInt64
        let size: UInt64
        let modified: Date

        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = a[.systemFileNumber] as? NSNumber, let bytes = a[.size] as? NSNumber,
                  let date = a[.modificationDate] as? Date else { return nil }
            identity = inode.uint64Value
            size = bytes.uint64Value
            modified = date
        }
    }

    let url: URL
    private let original: Revision?

    init(_ url: URL) {
        self.url = url
        original = Revision(url)
    }

    func save(_ recording: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let original, original == Revision(url) else {
                throw CameraMovieError.message("Another file was created or changed at the chosen destination.")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: recording)
        } else { try FileManager.default.moveItem(at: recording, to: url) }
    }
}

@MainActor
final class CameraRecorderWindow: NSObject, ObservableObject {
    static let shared = CameraRecorderWindow()
    enum Phase { case idle, starting, recording, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sources = [CameraSource]()
    @Published private(set) var cameras = [AVCaptureDevice]()
    @Published private(set) var loading = false
    @Published var sourceID = ""
    @Published var cameraID = ""
    @Published var microphone = true
    @Published var layout: CameraLayout {
        didSet {
            active?.update(layout: layout)
            if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "presenterLayout.v1") }
        }
    }
    @Published private(set) var preview: CGImage?
    @Published private(set) var status = ""
    @Published private(set) var lastMovie: URL?

    private var window: NSWindow?
    private var recordingItem: NSStatusItem?
    private let bubbleImage = NSImageView()
    private var bubble: NSPanel?
    private var active: CameraCapture?
    private var destination: CameraDestination?
    private var workingURL: URL?
    private var pendingFailure: String?
    private var quitWhenSaved = false

    override init() {
        layout = UserDefaults.standard.data(forKey: "presenterLayout.v1").flatMap { try? JSONDecoder().decode(CameraLayout.self, from: $0) } ?? CameraLayout()
        super.init()
    }

    var isRecording: Bool { phase == .recording }
    var selectedSource: CameraSource? { sources.first { $0.id == sourceID } }

    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Record Screen with Camera"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: CameraRecorderView(controller: self))
            panel.minSize = CGSize(width: 520, height: 580)
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if phase == .idle {
            discoverCameras()
            if CGPreflightScreenCaptureAccess() { loadSources() }
        }
    }

    private func discoverCameras() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14, *) { types = [.builtInWideAngleCamera, .external, .continuityCamera] }
        else { types = [.builtInWideAngleCamera, .externalUnknown] }
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: types,
                                                   mediaType: .video, position: .unspecified).devices
        if !cameras.contains(where: { $0.uniqueID == cameraID }) {
            cameraID = cameras.first(where: { $0.position == .front })?.uniqueID
                ?? cameras.first(where: { $0.uniqueID == AVCaptureDevice.default(for: .video)?.uniqueID })?.uniqueID
                ?? cameras.first?.uniqueID ?? ""
        }
    }

    func loadSources() {
        guard !loading, phase == .idle else { return }
        loading = true
        discoverCameras()
        Task {
            defer { loading = false }
            do {
                sources = try await CameraSource.available()
                if selectedSource == nil { sourceID = sources.first?.id ?? "" }
                status = sources.isEmpty ? "No displays or windows are currently available." : ""
            } catch {
                status = "Allow screen capture for this app in System Settings → Privacy & Security, then reopen the recorder. \(error.localizedDescription)"
            }
        }
    }

    func start() {
        guard phase == .idle, let source = selectedSource, !cameraID.isEmpty else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.mpeg4Movie]
        save.canCreateDirectories = true
        save.title = "Save screen and camera recording"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH-mm-ss"
        save.nameFieldStringValue = "Presentation " + stamp.string(from: Date()) + ".mp4"
        guard save.runModal() == .OK, let url = save.url else { return }
        phase = .starting
        status = "Starting screen and camera…"
        preview = nil
        pendingFailure = nil
        let temp = url.deletingLastPathComponent().appendingPathComponent(".shad-recording-" + UUID().uuidString + ".mp4")
        destination = CameraDestination(url)
        workingURL = temp
        Task { [self] in
            do {
                guard await Self.authorized(.video) else { throw CameraMovieError.message("Allow Camera access for this app in System Settings → Privacy & Security.") }
                if microphone, !(await Self.authorized(.audio)) {
                    throw CameraMovieError.message("Allow Microphone access in System Settings → Privacy & Security, or switch off Microphone to record silently.")
                }
                let graph = try CameraCapture(url: temp, source: source, microphone: microphone, layout: layout) { [weak self] image, face in
                    Task { @MainActor in
                        guard let self, self.phase == .recording else { return }
                        self.preview = image
                        self.updateBubble(face, source: source)
                    }
                } onFailure: { [weak self] reason in
                    Task { @MainActor in self?.interrupted(reason) }
                }
                active = graph
                try await graph.start(cameraID: cameraID, microphone: microphone)
                phase = .recording
                status = "Recording · Click the red menu bar control to stop and save."
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop camera recording")
                item.button?.contentTintColor = .systemRed
                item.button?.title = " REC"
                item.button?.target = self
                item.button?.action = #selector(stopFromMenu)
                item.button?.toolTip = "Stop and save screen and camera recording"
                recordingItem = item
                Commands.changed()
                if let reason = pendingFailure { stop(reason: reason) }
                else { window?.orderOut(nil) }
            } catch {
                active = nil
                phase = .idle
                status = error.localizedDescription
                destination = nil
                workingURL = nil
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }

    // The recorder's own windows are excluded by the display capture filter. Users see
    // this click-through bubble locally while the encoder composites its own camera tile.
    private func updateBubble(_ face: CGImage, source: CameraSource) {
        if bubble == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            bubbleImage.imageScaling = .scaleAxesIndependently
            p.contentView = bubbleImage
            bubble = p
        }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let current = source.liveFrame()
        let target = CGRect(x: current.minX, y: primaryHeight - current.maxY, width: current.width, height: current.height)
        let position = layout.rect(in: target.size).offsetBy(dx: target.minX, dy: target.minY)
        bubble?.setFrame(position, display: true)
        bubbleImage.image = NSImage(cgImage: face, size: position.size)
        if bubble?.isVisible == false { bubble?.orderFrontRegardless() }
    }

    private static func authorized(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }

    private func interrupted(_ reason: String) {
        if phase == .starting { pendingFailure = reason }
        else if phase == .recording { stop(reason: reason) }
    }

    @objc private func stopFromMenu() { stop() }

    func stop(reason: String? = nil) {
        guard phase == .recording, let graph = active, let temp = workingURL, let destination else { return }
        phase = .finishing
        if let item = recordingItem { NSStatusBar.system.removeStatusItem(item) }
        recordingItem = nil
        bubble?.orderOut(nil)
        bubbleImage.image = nil
        status = "Finishing MP4…"
        Commands.changed()
        Task {
            var finalized = false
            var saved = false
            do {
                try await graph.finish()
                finalized = true
                try destination.save(temp)
                lastMovie = destination.url
                saved = true
                status = reason.map { "Recording stopped. " + $0 + " The available footage was saved." } ?? "Saved " + destination.url.lastPathComponent
                Feedback.show(status)
            } catch {
                if finalized || graph.hasRecordedFrames {
                    let recovery = temp.deletingLastPathComponent().appendingPathComponent("Recovered recording " + UUID().uuidString + ".mp4")
                    do { try FileManager.default.moveItem(at: temp, to: recovery); lastMovie = recovery }
                    catch { lastMovie = temp }
                    status = error.localizedDescription + (finalized ? " The completed recording is available in Finder." : " The unfinished file is available in Finder.")
                } else {
                    try? FileManager.default.removeItem(at: temp)
                    status = [reason, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
                }
            }
            active = nil
            self.destination = nil
            workingURL = nil
            preview = nil
            phase = .idle
            if quitWhenSaved {
                quitWhenSaved = false
                NSApp.reply(toApplicationShouldTerminate: saved)
                if saved { return }
            }
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        switch phase {
        case .idle: return .terminateNow
        case .starting: return .terminateCancel
        case .finishing: quitWhenSaved = true; return .terminateLater
        case .recording:
            let alert = NSAlert()
            alert.messageText = "Save your recording before quitting?"
            alert.addButton(withTitle: "Stop, Save and Quit")
            alert.addButton(withTitle: "Keep Recording")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            quitWhenSaved = true
            stop()
            return .terminateLater
        }
    }
}

private struct CameraRecorderView: View {
    @ObservedObject var controller: CameraRecorderWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("Capture")
                    HStack {
                        if controller.sources.isEmpty {
                            Button(controller.loading ? "Loading…" : "Load screens and windows") { controller.loadSources() }
                                .disabled(controller.loading)
                        } else {
                            Picker("Source", selection: $controller.sourceID) {
                                ForEach(controller.sources) { Text($0.title).tag($0.id) }
                            }.labelsHidden()
                            Button { controller.loadSources() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Refresh capture sources").accessibilityLabel("Refresh capture sources")
                        }
                    }
                }.disabled(controller.phase != .idle)
                GridRow {
                    Text("Camera")
                    HStack {
                        if controller.cameras.isEmpty { Text("Connect a camera and refresh sources.").foregroundStyle(.secondary) }
                        else {
                            Picker("Camera", selection: $controller.cameraID) {
                                ForEach(controller.cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                            }.labelsHidden()
                        }
                        Toggle("Microphone", isOn: $controller.microphone)
                    }
                }.disabled(controller.phase != .idle)
                GridRow {
                    Text("Shape")
                    Picker("Shape", selection: $controller.layout.shape) {
                        ForEach(CameraShape.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                }
                GridRow {
                    Text("Background")
                    HStack {
                        Picker("Camera background", selection: $controller.layout.background) {
                            ForEach(CameraBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        Toggle("Mirror", isOn: $controller.layout.mirrored)
                    }
                }
                GridRow {
                    Text("Size")
                    HStack {
                        Slider(value: $controller.layout.size, in: 0.1...0.6, step: 0.01).accessibilityLabel("Camera overlay size")
                        Text("\(Int((controller.layout.size * 100).rounded()))%").monospacedDigit().frame(width: 36)
                    }
                }
                GridRow {
                    Text("Position")
                    HStack {
                        ForEach(Array(["Top left", "Top right", "Bottom left", "Bottom right"].enumerated()), id: \.offset) { index, title in
                            Button(title) {
                                controller.layout.x = index.isMultiple(of: 2) ? 0 : 1
                                controller.layout.y = index < 2 ? 0 : 1
                            }.controlSize(.small)
                        }
                    }
                }
            }.font(.system(size: 13))
            if !controller.status.isEmpty { Text(controller.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack {
                if let movie = controller.lastMovie {
                    Button("Show last recording") { NSWorkspace.shared.activateFileViewerSelecting([movie]) }
                }
                Spacer()
                if controller.phase == .recording { Button("Stop and save") { controller.stop() }.buttonStyle(.borderedProminent).tint(.red) }
                else {
                    Button(controller.phase == .starting ? "Starting…" : controller.phase == .finishing ? "Saving…" : "Start recording…") {
                        controller.start()
                    }.buttonStyle(.borderedProminent).disabled(controller.selectedSource == nil || controller.cameraID.isEmpty || controller.phase != .idle)
                }
            }
        }.padding(22)
    }

    private var preview: some View {
        let size = controller.selectedSource?.movieSize ?? CGSize(width: 16, height: 9)
        return GeometryReader { g in
            let factor = min(g.size.width / size.width, g.size.height / size.height)
            let screen = CGSize(width: size.width * factor, height: size.height * factor)
            ZStack {
                if let image = controller.preview {
                    Image(decorative: image, scale: 1.0).resizable()
                } else {
                    Rectangle().fill(LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.22, green: 0.26, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "display").font(.largeTitle).foregroundStyle(.white.opacity(0.35))
                    let rect = controller.layout.rect(in: screen)
                    let radius = controller.layout.shape == .circle ? rect.width / 2 : controller.layout.shape == .rounded ? rect.width * 0.18 : 0
                    ZStack {
                        RoundedRectangle(cornerRadius: radius).fill(.white.opacity(controller.layout.background == .original ? 0.22 : 0.06))
                        Image(systemName: "person.fill").resizable().scaledToFit().padding(rect.width * 0.18).foregroundStyle(.white)
                    }.frame(width: rect.width, height: rect.height).position(x: rect.midX, y: screen.height - rect.midY)
                }
            }
            .frame(width: screen.width, height: screen.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let rect = controller.layout.rect(in: screen)
                let inset = (min(screen.width, screen.height) * 0.025).rounded()
                controller.layout.x = min(1, max(0, (gesture.location.x - rect.width / 2 - inset) / max(1, screen.width - rect.width - 2 * inset)))
                controller.layout.y = min(1, max(0, (gesture.location.y - rect.height / 2 - inset) / max(1, screen.height - rect.height - 2 * inset)))
            })
            .help("Drag to position the camera overlay")
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minHeight: 170, maxHeight: 340)
    }
}
