import AppKit
import Foundation
import SQLite3
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

    @Test func keepsOriginalFormatsCopyTimesAndSourceAcrossEditions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = ClipboardStore(directory: dir), b = ClipboardStore(directory: dir)
        let first = Date(timeIntervalSince1970: 42), last = first.addingTimeInterval(3)
        let plain = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Hi".utf8))
        let rich = ClipboardRepresentation(type: "public.html", data: Data("<b>Hi</b>".utf8))
        let original = ClipboardCapture(content: .text("Hi"), items: [[plain, rich]], sourceBundleID: "sample.one", sourceName: "One")
        var later = original
        later.sourceName = "Two"; later.sourceBundleID = "sample.two"
        #expect(try a.record(original, observing: "g1", at: first))
        let saved = try #require(try b.entries().first)
        try b.rename(saved.id, to: "Welcome")
        try b.setPinned(saved.id, true)
        #expect(try !b.record(original, observing: "g1", at: last))
        #expect(try a.record(later, observing: "g3", at: last))
        #expect(try b.record(original, observing: "g2", at: first.addingTimeInterval(1)))
        let entry = try #require(try b.entries().first)
        #expect(entry.firstCopiedAt == first && entry.copiedAt == last && entry.copyCount == 3)
        #expect(entry.title == "Welcome" && entry.isPinned && entry.id == saved.id)
        #expect(entry.sourceName == "Two" && entry.sourceBundleID == "sample.two")
        #expect(entry.formatTypes == [plain.type, rich.type])
        #expect(try a.capture(for: entry.id) == later)
        var different = later
        different.items[0][1] = ClipboardRepresentation(type: rich.type, data: Data("<i>Hi</i>".utf8))
        #expect(try b.record(different, observing: "g4", at: last.addingTimeInterval(1)))
        #expect(try a.entries().count == 2)
    }

    @Test func editsReclassifyPreserveIdentityAndLeaveIndependentSnippets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        try store.record(.text("https://example.org"))
        let url = try #require(try store.entries().first)
        #expect(url.kind == .link)
        try store.saveSnippet(url.id, named: "Project address")
        try store.edit(url.id, text: "#abcdef")
        #expect(try store.entries().first?.kind == .color)
        try store.record(.text("https://example.org"))
        try store.edit(url.id, text: "hello@example.org")
        #expect(try store.entries().map(\.kind) == [.link, .email])
        try store.rename(url.id, to: "Contact")
        #expect(try store.entries(matching: "example.org").count == 2)
        #expect(try store.entries(matching: "Contact").first?.id == url.id)
        try store.clear()
        #expect(try store.entries().isEmpty)
        let snippet = try #require(try store.snippets(matching: "Project").first)
        #expect(snippet.isSnippet && snippet.title == "Project address")
        #expect(try store.capture(for: snippet.id)?.content == .text("https://example.org"))
        try store.rename(snippet.id, to: "Template")
        try store.edit(snippet.id, text: "Many thanks")
        #expect(try store.snippets(matching: "THANKS").first?.title == "Template")
        try store.remove(snippet.id)
        #expect(try store.snippets().isEmpty)
    }

    @Test func retainsFileGroupsPinnedItemsAndSearchableRecognition() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir, maxEntries: 3)
        let urls = ["One.png", "Two.pdf"].map { dir.appendingPathComponent($0) }
        let files = ClipboardCapture(content: .files(urls), items: urls.map {
            [ClipboardRepresentation(type: "public.file-url", data: Data($0.absoluteString.utf8))]
        }, sourceName: "Finder")
        let date = Date(timeIntervalSince1970: 100)
        try store.record(files, observing: "files", at: date)
        let group = try #require(try store.entries(matching: "Two.pdf").first)
        #expect(group.kind == .files && group.itemCount == 2)
        #expect(try store.capture(for: group.id) == files)
        try store.setPinned(group.id, true)
        for value in 1...5 { try store.record(.text(String(value)), at: date.addingTimeInterval(Double(value))) }
        #expect(try store.entries().map(\.title) == [group.title, "5", "4"])
        try store.clear(since: date.addingTimeInterval(5))
        #expect(try store.entries().map(\.title) == [group.title, "4"])
        try store.clear(since: date)
        #expect(try store.entries().map(\.id) == [group.id])
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try store.record(.image(bytes))
        let image = try #require(try store.entries().first(where: { $0.kind == .image }))
        #expect(image.pixelWidth == 6 && image.pixelHeight == 4)
        try store.setRecognizedText("Three little birds", for: image.id)
        #expect(try store.entries(matching: "LITTLE BIRDS").map(\.id) == [image.id])
        let text = ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("Caption".utf8))
        let picture = ClipboardRepresentation(type: "public.png", data: bytes)
        let mixed = ClipboardCapture(content: .text("Caption"), items: [[text], [picture]])
        try store.record(mixed, observing: "mixed", at: Date())
        let mixedID = try #require(try store.entries(matching: "Caption").first?.id)
        try store.setRecognizedText("Text in the second member", for: mixedID)
        #expect(try store.entries(matching: "second member").map(\.id) == [mixedID])
        try store.edit(mixedID, text: "Edited caption")
        try store.setRecognizedText("Late OCR", for: mixedID)
        #expect(try store.entries(matching: "Late OCR").isEmpty)
        try store.clear(since: date, includingPinned: true)
        #expect(try store.entries().isEmpty)
    }

    @Test func migratesExistingHistoryInPlaceWithoutInventingSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var legacy: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("history.sqlite3").path, &legacy) == SQLITE_OK)
        let legacyDB = try #require(legacy)
        let schema = """
            CREATE TABLE entries (id TEXT NOT NULL UNIQUE,kind TEXT NOT NULL,title TEXT NOT NULL,copied REAL NOT NULL,
                bytes INTEGER NOT NULL,thumbnail BLOB,payload BLOB NOT NULL);
            CREATE TABLE settings(name TEXT PRIMARY KEY);
            CREATE TABLE observations(token TEXT NOT NULL UNIQUE);
            INSERT INTO settings VALUES('paused');
            INSERT INTO entries VALUES('old','text','#f00',42,4,NULL,CAST('#f00' AS BLOB));
            """
        #expect(sqlite3_exec(legacyDB, schema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(legacyDB)
        let store = ClipboardStore(directory: dir)
        let row = try #require(try store.entries().first)
        #expect(row.id == "old" && row.kind == .color && row.firstCopiedAt == row.copiedAt && row.copyCount == 1)
        #expect(row.sourceName == nil && row.sourceBundleID == nil && row.formatTypes == ["public.utf8-plain-text"])
        #expect(try store.content(for: row.id) == .text("#f00"))
        #expect(try store.isPaused())
    }
}
