import AppKit
import AVFoundation
import ScreenCaptureKit

struct CameraSource: Identifiable {
    let id: String
    let title: String
    let frame: CGRect
    var size: CGSize { frame.size }
    let filter: SCContentFilter
    let windowID: CGWindowID?
    let excludesRecorder: Bool

    func liveFrame() -> CGRect {
        guard let windowID,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"], w > 0, h > 0 else { return frame }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func available() async throws -> [Self] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let own = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == own }
        let mainID = CGMainDisplayID()
        let displays = content.displays.sorted { lhs, rhs in
            lhs.displayID == mainID && rhs.displayID != mainID
        }
        let screens = displays.enumerated().map { index, display in
            let name = "Display \(index + 1)" + (display.displayID == mainID ? " (main)" : "")
            return Self(id: "d\(display.displayID)", title: name, frame: display.frame,
                        filter: SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: []),
                        windowID: nil, excludesRecorder: !excluded.isEmpty)
        }
        let windows = content.windows.compactMap { window -> Self? in
            guard window.windowLayer == 0, let owner = window.owningApplication, owner.processID != own,
                  let title = window.title, !title.isEmpty, window.frame.width >= 80, window.frame.height >= 60 else { return nil }
            return Self(id: "w\(window.windowID)", title: "\(owner.applicationName) · \(title)", frame: window.frame,
                        filter: SCContentFilter(desktopIndependentWindow: window), windowID: window.windowID, excludesRecorder: true)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return screens + windows
    }

    var movieSize: CGSize {
        let scale = min(2, 1920 / max(size.width, size.height))
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2), height: max(2, floor(size.height * scale / 2) * 2))
    }
}

// Screen, camera, microphone, composition and encoder callbacks share one serial queue.
// A timer samples both latest images so the presenter keeps moving over a stationary desktop.
final class CameraCapture: NSObject, SCStreamOutput, SCStreamDelegate,
                           AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "shad.capture.presenter", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "shad.capture.presenter.session", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let movie: CameraMovieWriter
    private let onPreview: (CGImage, CGImage) -> Void
    private let onFailure: (String) -> Void
    private var stream: SCStream?
    private var observers = [NSObjectProtocol]()
    private var timer: DispatchSourceTimer?
    private var screenBuffer: CVPixelBuffer?
    private var cameraBuffer: CVPixelBuffer?
    private var mask: CIImage?
    private var lastMaskTime: TimeInterval = 0
    private var lastPreviewTime: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var stopping = false
    private var failed = false
    private var layout: CameraLayout
    private let personMatte = CameraPersonMatte()

    init(url: URL, source: CameraSource, microphone: Bool, layout: CameraLayout,
         onPreview: @escaping (CGImage, CGImage) -> Void, onFailure: @escaping (String) -> Void) throws {
        guard source.excludesRecorder else { throw CameraMovieError.message("Refresh the capture sources while the recorder window is visible, then select the display again.") }
        movie = try CameraMovieWriter(url: url, size: source.movieSize, microphone: microphone)
        self.layout = layout
        self.onPreview = onPreview
        self.onFailure = onFailure
        super.init()
        let configuration = SCStreamConfiguration()
        configuration.width = Int(source.movieSize.width)
        configuration.height = Int(source.movieSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: source.filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start(cameraID: String, microphone: Bool) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionQueue.async {
                    do {
                        try self.configureCamera(cameraID, microphone: microphone)
                        self.session.startRunning()
                        guard self.session.isRunning else { throw CameraMovieError.message("The camera could not start. Check the device and try again.") }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try await stream?.startCapture()
            queue.async { [self] in
                self.startedAt = ProcessInfo.processInfo.systemUptime
                let ticker = DispatchSource.makeTimerSource(queue: self.queue)
                ticker.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
                ticker.setEventHandler { [weak self] in self?.tick() }
                self.timer = ticker
                ticker.resume()
            }
        } catch {
            await halt()
            movie.cancel()
            throw error
        }
    }

    private func configureCamera(_ id: String, microphone: Bool) throws {
        guard let device = AVCaptureDevice(uniqueID: id) else { throw CameraMovieError.message("The selected camera is disconnected.") }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraMovieError.message("Could not connect the selected camera.") }
        session.addInput(input)
        let frames = AVCaptureVideoDataOutput()
        frames.alwaysDiscardsLateVideoFrames = true
        frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        frames.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(frames) else { throw CameraMovieError.message("Video output is unavailable.") }
        session.addOutput(frames)
        if let connection = frames.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        var devices = [device]
        if microphone {
            guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraMovieError.message("No microphone is available. Connect one or switch off Microphone.") }
            let input = try AVCaptureDeviceInput(device: mic)
            let audio = AVCaptureAudioDataOutput()
            guard session.canAddInput(input) else { throw CameraMovieError.message("Could not connect the microphone.") }
            session.addInput(input)
            guard session.canAddOutput(audio) else { throw CameraMovieError.message("Microphone audio output is unavailable.") }
            session.addOutput(audio)
            audio.setSampleBufferDelegate(self, queue: queue)
            devices.append(mic)
        }
        for device in devices {
            observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureDeviceWasDisconnected, object: device, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.fail("A recording device disconnected.") }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.queue.async { [weak self] in self?.fail(error?.localizedDescription ?? "Camera capture was interrupted.") }
        })
    }

    func update(layout: CameraLayout) {
        queue.async { self.layout = layout }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopping, !failed else { return }
        if output is AVCaptureVideoDataOutput {
            cameraBuffer = CMSampleBufferGetImageBuffer(sample)
        } else {
            do { try movie.appendAudio(sample) } catch { fail(error.localizedDescription) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = sampleBuffer.imageBuffer else { return }
        screenBuffer = image
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail(error.localizedDescription) }
    }

    private func tick() {
        guard !stopping, !failed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let screenBuffer, let cameraBuffer else {
            if now - startedAt > 12 { fail("Screen or camera frames did not arrive. Check the selected devices and macOS permissions.") }
            return
        }
        if layout.background == .person, now - lastMaskTime >= 1.0 / 15.0 {
            lastMaskTime = now
            do {
                mask = try personMatte.mask(for: cameraBuffer)
            } catch { fail("Person cutout could not process the camera image. \(error.localizedDescription)"); return }
        }
        let time = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
        do {
            guard let composed = try movie.append(screen: CIImage(cvPixelBuffer: screenBuffer), camera: CIImage(cvPixelBuffer: cameraBuffer),
                                                  mask: mask, layout: layout, at: time) else { return }
            if now - lastPreviewTime >= 0.15 {
                lastPreviewTime = now
                let factor = min(1, 480 / composed.extent.width, 340 / composed.extent.height)
                let thumbnail = composed.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                let side = min(360, layout.rect(in: movie.canvas).width)
                let tile = movie.compositor.cameraTile(camera: CIImage(cvPixelBuffer: cameraBuffer), mask: mask, layout: layout,
                                                       size: CGSize(width: side, height: side))
                if let image = movie.compositor.context.createCGImage(thumbnail, from: thumbnail.extent),
                   let face = movie.compositor.context.createCGImage(tile, from: tile.extent) {
                    onPreview(image, face)
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    private func fail(_ reason: String) {
        guard !stopping, !failed else { return }
        failed = true
        onFailure(reason)
    }

    private func halt() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopping = true
                self.timer?.cancel()
                self.timer = nil
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.observers.forEach { NotificationCenter.default.removeObserver($0) }
                self.observers.removeAll()
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
        try? await stream?.stopCapture()
        if let stream { try? stream.removeStreamOutput(self, type: .screen) }
        stream = nil
    }

    /// Read after finish returns, when both sample queues have stopped.
    var hasRecordedFrames: Bool { movie.hasFrames }

    func finish() async throws {
        await halt()
        try await movie.finish()
    }
}
