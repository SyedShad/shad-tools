import AppKit
import Foundation
import Testing
@testable import ShadTools

@Suite("Clipboard history storage")
struct ClipboardStoreTests {
    @Test func persistsTextImagesAndTheirPreviews() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let original = String(repeating: "line ", count: 40) + "\nÉtude 10%_\u{0}🎵"
        let early = Date(timeIntervalSince1970: 100)
        try store.record(.text(original), at: early)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 5, pixelsHigh: 3,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try store.record(.image(png), at: early.addingTimeInterval(1))
        let reopened = ClipboardStore(directory: dir)
        let rows = try reopened.entries()
        try #require(rows.count == 2)
        #expect(rows.map(\.kind) == [.image, .text])
        #expect(rows[0].thumbnail.flatMap(NSImage.init(data:)) != nil)
        #expect(rows[1].thumbnail == nil)
        #expect(rows[1].copiedAt == early)
        #expect(rows[1].byteCount == original.utf8.count)
        #expect(try reopened.content(for: rows[0].id) == .image(png))
        #expect(try reopened.content(for: rows[1].id) == .text(original))
        #expect(try reopened.entries(matching: "ÉTUDE 10%_").map(\.id) == [rows[1].id])
        #expect(try reopened.entries(matching: "100%_").isEmpty)
        #expect(try reopened.entries(matching: "🎵").count == 1)
        try reopened.record(.text(original), at: early.addingTimeInterval(2))
        #expect(try store.entries().map(\.id) == [rows[1].id, rows[0].id])
        #expect(try !store.record(.text(original), at: early))
        #expect(try store.entries().first?.copiedAt == early.addingTimeInterval(2))
        let db = dir.appendingPathComponent("history.sqlite3")
        #expect((try FileManager.default.attributesOfItem(atPath: db.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func enforcesItemCountPayloadAndByteLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir, maxEntries: 3, maxBytes: 10, maxItemBytes: 7)
        for (index, text) in ["a", "b", "c", "d", "eee", "fffffff"].enumerated() {
            #expect(try store.record(.text(text), at: Date(timeIntervalSince1970: Double(index))))
            if index == 3 { #expect(try store.entries().map(\.title) == ["d", "c", "b"]) }
        }
        #expect(try !store.record(.text("12345678")))
        #expect(try !store.record(.text("")))
        #expect(try !store.record(.image(Data("bad PNG".utf8))))
        #expect(try store.entries().map(\.title) == ["fffffff", "eee"])
    }

    @Test func concurrentWritersSharePauseDeletionAndClear() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = ClipboardStore(directory: dir)
        let standalone = ClipboardStore(directory: dir)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    let store = writer % 2 == 0 ? suite : standalone
                    for item in 0..<6 { try store.record(.text("\(writer)-\(item)")) }
                }
            }
            try await group.waitForAll()
        }
        let rows = try standalone.entries()
        #expect(rows.count == 24)
        try suite.setPaused(true)
        #expect(try standalone.isPaused())
        #expect(try !standalone.record(.text("paused")))
        let first = try #require(rows.first)
        try standalone.remove(first.id)
        #expect(try suite.content(for: first.id) == nil)
        try suite.clear()
        #expect(try standalone.entries().isEmpty)
        #expect(try standalone.isPaused())
        try standalone.setPaused(false)
        #expect(try !suite.isPaused())
        #expect(try suite.record(.text("resumed")))
        #expect(try standalone.entries().map(\.title) == ["resumed"])
    }

    @Test func sharedObserversKeepBatchOrderAndNeverReinsertDeletedCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = ClipboardStore(directory: dir)
        let standalone = ClipboardStore(directory: dir)
        let first = Date(timeIntervalSince1970: 20)
        let second = first.addingTimeInterval(1)
        try suite.record([.text("A"), .text("B")], observing: "boot:board:1", at: first)
        #expect(try suite.entries().map(\.title) == ["A", "B"])
        let reversed: [ClipboardContent] = [.text("B"), .text("A")]
        try standalone.record(reversed, observing: "boot:board:2", at: second)
        #expect(try suite.entries().map(\.title) == ["B", "A"])
        let id = try #require(suite.entries().first?.id)
        try suite.remove(id)
        #expect(try !suite.record(reversed, observing: "boot:board:2", at: second.addingTimeInterval(1)))
        #expect(try standalone.entries().map(\.title) == ["A"])
        try standalone.clear()
        #expect(try !suite.record(reversed, observing: "boot:board:2", at: second.addingTimeInterval(2)))
        #expect(try standalone.entries().isEmpty)
        #expect(try suite.record(reversed, observing: "boot:board:3", at: second.addingTimeInterval(3)))
    }
}
