import AVFoundation
import CoreImage
import Vision

enum CameraShape: String, CaseIterable, Codable {
    case circle = "Circle"
    case square = "Square"
    case rounded = "Rounded square"
}

enum CameraBackground: String, CaseIterable, Codable {
    case original = "Original"
    case greenScreen = "Remove green screen"
    case person = "Person cutout"
}

struct CameraLayout: Equatable, Codable {
    var shape: CameraShape = .circle
    var background: CameraBackground = .original
    var size = 0.24
    var x = 1.0
    var y = 1.0
    var mirrored = true

    // x/y are normalized in the area through which the overlay can travel.
    func rect(in canvas: CGSize) -> CGRect {
        let shortEdge = min(canvas.width, canvas.height)
        let side = (shortEdge * min(0.60, max(0.10, size))).rounded()
        let inset = (shortEdge * 0.025).rounded()
        let left = inset + (canvas.width - side - 2 * inset) * min(1, max(0, x))
        let bottom = inset + (canvas.height - side - 2 * inset) * (1 - min(1, max(0, y)))
        return CGRect(x: left.rounded(), y: bottom.rounded(), width: side, height: side)
    }
}

enum CameraMovieError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

final class CameraPersonMatte {
    private lazy var segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .fast
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    func mask(for image: CVPixelBuffer) throws -> CIImage? {
        try VNImageRequestHandler(cvPixelBuffer: image).perform([segmentation])
        return segmentation.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
    }
}

final class CameraCompositor {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [.workingColorSpace: CameraCompositor.colorSpace,
                                      .cacheIntermediates: false])

    private static let greenCube: Data = {
        let n = 32
        var values = [Float]()
        values.reserveCapacity(n * n * n * 4)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let red = Float(r) / Float(n - 1)
                    let green = Float(g) / Float(n - 1)
                    let blue = Float(b) / Float(n - 1)
                    let excess = green - max(red, blue)
                    let t = max(0, min(1, (excess - 0.07) / 0.19))
                    let alpha = 1 - t * t * (3 - 2 * t)
                    values += [red * alpha, (green - max(0, excess) * t) * alpha, blue * alpha, alpha]
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }()

    func frame(screen: CIImage, camera: CIImage, mask: CIImage?, layout: CameraLayout, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        let background = fit(screen, into: bounds)
        let destination = layout.rect(in: canvas)
        let tile = cameraTile(camera: camera, mask: mask, layout: layout, size: destination.size)
            .transformed(by: CGAffineTransform(translationX: destination.minX, y: destination.minY))
        return tile.composited(over: background).cropped(to: bounds)
    }

    func cameraTile(camera: CIImage, mask: CIImage?, layout: CameraLayout, size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let side = min(camera.extent.width, camera.extent.height)
        let crop = CGRect(x: camera.extent.midX - side / 2, y: camera.extent.midY - side / 2, width: side, height: side)
        var subject = camera
        switch layout.background {
        case .original: break
        case .greenScreen:
            subject = camera.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 32, "inputCubeData": Self.greenCube, "inputColorSpace": Self.colorSpace
            ])
        case .person:
            // Until Vision supplies a mask, keep the room out of the export.
            guard let mask else { return CIImage(color: .clear).cropped(to: bounds) }
            subject = camera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fit(mask, into: camera.extent)
            ])
        }
        var tile = fit(subject.cropped(to: crop), into: bounds)
        if layout.mirrored {
            tile = tile.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0))
        }
        if layout.shape != .square {
            let radius = size.width * (layout.shape == .circle ? 0.5 : 0.18)
            let rounded = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: tile.extent), "inputRadius": radius, "inputColor": CIColor.white
            ])!.outputImage!
            tile = tile.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: rounded
            ])
        }
        return tile.cropped(to: bounds)
    }

    private func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / image.extent.width, y: rect.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

final class CameraMovieWriter {
    let canvas: CGSize
    let compositor = CameraCompositor()
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private(set) var hasFrames = false
    private var origin: CMTime?

    init(url: URL, size: CGSize, microphone: Bool) throws {
        canvas = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let width = Int(size.width), height = Int(size.height)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(700_000, width * height * 4),
                                              AVVideoExpectedSourceFrameRateKey: 30]
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        guard writer.canAdd(video) else { throw CameraMovieError.message("H.264 video encoding is unavailable.") }
        writer.add(video)
        if microphone {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000
            ])
            track.expectsMediaDataInRealTime = true
            guard writer.canAdd(track) else { throw CameraMovieError.message("AAC microphone encoding is unavailable.") }
            writer.add(track)
            audio = track
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? CameraMovieError.message("Could not create the recording.") }
    }

    @discardableResult
    func append(screen: CIImage, camera: CIImage, mask: CIImage?, layout: CameraLayout, at time: CMTime) throws -> CIImage? {
        guard writer.status == .writing else { throw writer.error ?? CameraMovieError.message("The recording stopped accepting frames.") }
        if origin == nil { writer.startSession(atSourceTime: time); origin = time }
        guard video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw CameraMovieError.message("Could not allocate the video frame.")
        }
        let image = compositor.frame(screen: screen, camera: camera, mask: mask, layout: layout, canvas: canvas)
        compositor.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: canvas), colorSpace: CameraCompositor.colorSpace)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? CameraMovieError.message("The video encoder rejected a frame.")
        }
        hasFrames = true
        return image
    }

    func appendAudio(_ buffer: CMSampleBuffer) throws {
        guard let origin, let audio, CMSampleBufferGetPresentationTimeStamp(buffer) >= origin, audio.isReadyForMoreMediaData else { return }
        guard audio.append(buffer) else { throw writer.error ?? CameraMovieError.message("The microphone track could not be encoded.") }
    }

    func finish() async throws {
        guard hasFrames else { writer.cancelWriting(); throw CameraMovieError.message("No screen and camera frames were received. Check camera access and Screen Recording permission, then try again.") }
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CameraMovieError.message("Could not finish the recording.") }
    }

    func cancel() { if writer.status == .writing { writer.cancelWriting() } }
}
