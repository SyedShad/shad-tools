import AVFoundation
import CoreImage
import Testing
@testable import ShadTools

@Suite("Presentation recording")
struct CameraRecorderTests {
    @Test func clampsAndPositionsOverlayInsideLandscapeAndPortrait() {
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 1400)] {
            var layout = CameraLayout()
            layout.size = 9
            layout.x = -2
            layout.y = 2
            let first = layout.rect(in: canvas)
            #expect(first.width == (min(canvas.width, canvas.height) * 0.60).rounded())
            #expect(first.minX > 0 && first.minY > 0)
            layout.x = 1
            layout.y = 0
            let opposite = layout.rect(in: canvas)
            #expect(abs(canvas.width - opposite.maxX - first.minX) < 1)
            #expect(abs(canvas.height - opposite.maxY - first.minY) < 1)
        }
    }

    @Test func savingProtectsFilesThatChangedDuringRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("recording.mp4"), staging = folder.appendingPathComponent("staging.mp4")
        let initial = CameraDestination(file)
        try Data("new movie".utf8).write(to: staging)
        try Data("another file".utf8).write(to: file)
        #expect(throws: (any Error).self) { try initial.save(staging) }
        #expect(try Data(contentsOf: file) == Data("another file".utf8))
        let confirmedOverwrite = CameraDestination(file)
        try confirmedOverwrite.save(staging)
        #expect(try Data(contentsOf: file) == Data("new movie".utf8))
    }

    @Test func exportedMP4ContainsCameraShapesKeyPositionAndAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Shad-camera-test-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 320, height: 180)
        let bounds = CGRect(origin: .zero, size: size)
        let cameraBounds = CGRect(x: 0, y: 0, width: 96, height: 96)
        let screen = CIImage(color: .blue).cropped(to: bounds)
        let red = CIImage(color: .red).cropped(to: cameraBounds)
        let left = CGRect(x: 0, y: 0, width: 48, height: 96)
        let camera = CIImage(color: .green).cropped(to: left).composited(over: red)
        let personMask = CIImage(color: .black).cropped(to: left).composited(over: CIImage(color: .white).cropped(to: cameraBounds))
        let movie = try CameraMovieWriter(url: url, size: size, microphone: true)
        var layout = CameraLayout()
        layout.size = 0.5
        layout.mirrored = false
        var rectangles: [CGRect] = []
        // One second per style. Switching layout while recording follows the same append path.
        for scene in 0..<7 {
            layout.shape = [.circle, .square, .rounded, .square, .square, .square, .square][scene]
            layout.background = [.original, .original, .original, .greenScreen, .person, .person, .greenScreen][scene]
            if scene == 6 {
                layout.mirrored = true
                layout.size = 0.30
                layout.x = 0
                layout.y = 0
            }
            rectangles.append(layout.rect(in: size))
            for frame in 0..<8 {
                let pts = CMTime(value: Int64(scene * 8 + frame), timescale: 8)
                var wrote = false
                for _ in 0..<100 where !wrote {
                    wrote = try movie.append(screen: screen, camera: scene < 3 ? red : camera, mask: scene == 5 ? nil : personMask,
                                             layout: layout, at: pts) != nil
                    if !wrote { try await Task.sleep(nanoseconds: 5_000_000) }
                }
                try #require(wrote)
                try movie.appendAudio(Self.silence(at: pts))
            }
        }
        try await movie.finish()
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1)
        #expect(audioTracks.count == 1)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 6.8)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext(options: [.workingColorSpace: CameraCompositor.colorSpace])
        func dominant(_ image: CIImage, _ rect: CGRect, _ x: Double, _ y: Double) -> Int {
            let pixel = CGRect(x: floor(rect.minX + x * rect.width), y: floor(rect.minY + y * rect.height), width: 1, height: 1)
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &rgba, rowBytes: 4, bounds: pixel, format: .RGBA8, colorSpace: CameraCompositor.colorSpace)
            return (0..<3).max(by: { rgba[$0] < rgba[$1] })!
        }
        for scene in 0..<7 {
            let cg = try generator.copyCGImage(at: CMTime(value: Int64(scene * 8 + 4), timescale: 8), actualTime: nil)
            let frame = CIImage(cgImage: cg)
            let r = rectangles[scene]
            switch scene {
            case 0: // Circle cuts away a larger section of the corner.
                #expect(dominant(frame, r, 0.12, 0.12) == 2)
                #expect(dominant(frame, r, 0.5, 0.5) == 0)
            case 1:
                #expect(dominant(frame, r, 0.02, 0.02) == 0)
            case 2:
                #expect(dominant(frame, r, 0.02, 0.02) == 2)
                #expect(dominant(frame, r, 0.12, 0.12) == 0)
            case 3, 4:
                #expect(dominant(frame, r, 0.25, 0.5) == 2)
                #expect(dominant(frame, r, 0.75, 0.5) == 0)
            case 5: // A missing person mask cannot reveal the room.
                #expect(dominant(frame, r, 0.75, 0.5) == 2)
            default:
                #expect(dominant(frame, r, 0.25, 0.5) == 0)
                #expect(dominant(frame, r, 0.75, 0.5) == 2)
                #expect(dominant(frame, rectangles[0], 0.5, 0.5) == 2)
            }
        }
    }

    private static func silence(at time: CMTime) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let frames = 6000
        var block: CMBlockBuffer?
        try #require(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: frames * 2, flags: 0, blockBufferOut: &block) == noErr)
        let data = try #require(block)
        try #require(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: frames * 2) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var packetSize = 2
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReady(allocator: nil, dataBuffer: data, formatDescription: format.formatDescription,
                                               sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &packetSize, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
