import AppKit
import SQLite3
import Testing
@testable import ShadClipboardFeature

@Suite("Clipboard collection and retention settings")
struct ClipboardPrivacyTests {
    private func updateFixture(_ directory: URL, sql: String) throws {
        var database: OpaquePointer?
        let path = directory.appendingPathComponent("history.sqlite3").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func usesLastCopyForExpiryAndKeepsPinsAndSnippetsAcrossEditions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = ClipboardStore(directory: directory), standalone = ClipboardStore(directory: directory)
        let eightDaysAgo = Date().addingTimeInterval(-8 * 86_400)
        for text in ["expired", "pinned", "repeated"] { try suite.record(.text(text), at: eightDaysAgo) }
        let expired = try #require(try suite.entries().first { $0.title == "expired" })
        let pinned = try #require(try suite.entries().first { $0.title == "pinned" })
        try suite.setPinned(pinned.id, true)
        try suite.saveSnippet(expired.id, named: "Saved")
        let snippet = try #require(try suite.snippets().first)
        try suite.record(.text("repeated"))

        try standalone.setRetention(.week)
        #expect(try suite.privacySettings().retention == .week)
        #expect(try suite.entries().map(\.title) == ["pinned", "repeated"])
        #expect(try suite.capture(for: expired.id) == nil)
        #expect(try suite.content(for: snippet.id) == .text("expired"))
        // Model time passing while both apps were closed. Even a direct paste must honor expiry.
        let cutoff = Int(eightDaysAgo.timeIntervalSince1970)
        try updateFixture(directory, sql: "UPDATE entries SET copied=\(cutoff)")
        let pinnedContent = try #require(try suite.content(for: pinned.id))
        #expect(pinnedContent == .text("pinned"))
        #expect(try standalone.entries().map(\.id) == [pinned.id])
        try suite.setPinned(pinned.id, false)
        #expect(try standalone.capture(for: pinned.id) == nil)
        #expect(try standalone.snippets().count == 1)
    }

    @Test func staleSelectionsAndExtendedRetentionCannotRecoverAnExpiredCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        try store.setRetention(.day)
        for action in ["snippet", "pin", "extend"] {
            try store.record(.text(action))
            let entry = try #require(try store.entries().first)
            try updateFixture(directory, sql: "UPDATE entries SET copied=1")
            switch action {
            case "snippet":
                #expect(throws: (any Error).self) { try store.saveSnippet(entry.id, named: "Expired") }
                #expect(try store.snippets().isEmpty)
            case "pin": try store.setPinned(entry.id, true)
            default: try store.setRetention(.noAgeLimit)
            }
            #expect(try store.entries().isEmpty)
        }
    }

    @Test @MainActor func suppressesForegroundAndEveryTaggedSourceAcrossEditions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let writer = ClipboardStore(directory: directory), reader = ClipboardStore(directory: directory)
        let tool = ClipboardTool(store: reader, pasteboard: board, monitor: false)
        let app = ClipboardExcludedApp(id: "Tests.Private", name: "Fixture")
        try writer.record(.text("already saved"))
        try writer.exclude([app])
        try reader.exclude([ClipboardExcludedApp(id: "test.second", name: "Second")])
        #expect(try writer.privacySettings().excludedApps.map(\.id) == ["tests.private", "test.second"])

        board.clearContents()
        board.setString("from frontmost", forType: .string)
        await tool.poll(frontmostBundleID: "Tests.Private.helper")
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setString("tests.public", forType: .init("org.nspasteboard.source"))
        second.setString("second", forType: .string)
        second.setString("Tests.Private", forType: .init("org.nspasteboard.source"))
        board.clearContents()
        #expect(board.writeObjects([first, second]))
        await tool.poll(frontmostBundleID: "tests.public")
        #expect(try writer.entries().map(\.title) == ["already saved"])

        // A capture can be prepared just before a different process excludes one origin.
        let inFlight = ClipboardCapture(content: .text("before commit"), sourceBundleID: "tests.public",
                                        observedBundleIDs: ["tests.public", "tests.private"])
        #expect(try !reader.record(inFlight, observing: "in-flight", at: Date()))
        try writer.removeExclusion("TESTS.PRIVATE")
        #expect(try !reader.record(inFlight, observing: "in-flight", at: Date()))
        board.clearContents()
        board.setString("new copy", forType: .string)
        await tool.poll(frontmostBundleID: "tests.private")
        #expect(try writer.entries().map(\.title) == ["new copy", "already saved"])
        #expect(try !writer.privacySettings().excludes("test.secondhand"))
    }

    @Test func migratesExistingHistoryWithoutSettingAnExpiryOrLosingPause() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        try store.record(.text("legacy"), at: Date(timeIntervalSince1970: 15))
        try store.setPaused(true)
        try updateFixture(directory, sql: "DROP TABLE excluded_apps; DROP TABLE history_retention; PRAGMA user_version=1")
        let upgraded = ClipboardStore(directory: directory)
        #expect(try upgraded.privacySettings() == ClipboardPrivacy())
        #expect(try upgraded.isPaused())
        #expect(try upgraded.entries().map(\.title) == ["legacy"])
    }
}
