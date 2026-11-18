import AppKit
import Foundation
import Testing
@testable import ShadCore
@testable import ShadClipboardFeature

@Suite("Clipboard item inspector")
struct ClipboardInspectorTests {
    @Test func countsDisplayedCharactersAndWords() {
        let inspection = ClipboardInspection.inspect(.text("Café and tea.\r\nSecond line 👨‍👩‍👧."))
        let properties = Dictionary(uniqueKeysWithValues: inspection.properties.map { ($0.name, $0.value) })
        #expect(properties["Characters"] == String("Café and tea.\r\nSecond line 👨‍👩‍👧.".count))
        #expect(properties["Words"] == "5")
        #expect(properties["Lines"] == "2")
    }

    @Test @MainActor func actionsFollowSelectionAndFilteringNeverPastesTheOldSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let date = Date()
        _ = try store.record(.text("Sample text"), at: date.addingTimeInterval(-2))
        _ = try store.record(.text("https://example.com/shad"), at: date)
        let board = NSPasteboard(name: .init("io.shadtools.tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let tool = ClipboardTool(store: store, pasteboard: board, monitor: false)
        let browser = HistoryBrowser(tool: tool)
        await tool.synchronize()
        browser.appear()
        defer { browser.disappear() }
        for _ in 0..<100 where browser.content == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(browser.selected?.kind == .link)
        browser.openMenu(.actions)
        #expect(browser.availableActions.contains { $0.id == "open" })
        #expect(!browser.availableActions.contains { $0.id == "qr" })
        browser.actionQuery = "rename"
        #expect(browser.availableActions.map(\.id) == ["rename"])
        browser.runSelectedAction()
        #expect(browser.editor == .rename)
        browser.cancelOverlay()
        browser.filter = .text
        #expect(browser.selected?.title == "Sample text")
        browser.query = "no matching item"
        #expect(browser.selected == nil)
    }
    @Test @MainActor func aBackgroundCopyPreservesAnEditorOnAFilteredEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(directory: folder)
        _ = try store.record(.text("Review the draft"))
        let board = NSPasteboard(name: .init("io.shadtools.tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let tool = ClipboardTool(store: store, pasteboard: board, monitor: false)
        let browser = HistoryBrowser(tool: tool)
        await tool.synchronize()
        browser.appear()
        defer { browser.disappear() }
        browser.query = "draft"
        for _ in 0..<100 where browser.content == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        browser.beginEdit(.edit)
        browser.draft = "Unsaved changes"
        _ = try store.record(.text("A different item"))
        await tool.synchronize()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(browser.editor == .edit)
        #expect(browser.draft == "Unsaved changes")
    }

    @Test @MainActor func groupsKeepWholeEntryActionsAndIdentifyPartialPreviews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let custom = ClipboardRepresentation(type: "com.example.data", data: Data([1, 3, 4]))
        let text = ClipboardRepresentation(type: plain, data: Data("Sample".utf8))
        let mixed = ClipboardCapture(content: .text("Sample"), items: [[custom], [text]])
        _ = try store.record(mixed, observing: "mixed", at: Date())
        let board = NSPasteboard(name: .init("io.shadtools.tests." + UUID().uuidString))
        defer { board.releaseGlobally() }
        let tool = ClipboardTool(store: store, pasteboard: board, monitor: false)
        let browser = HistoryBrowser(tool: tool)
        await tool.synchronize()
        browser.appear()
        defer { browser.disappear() }
        for _ in 0..<100 where browser.content == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(browser.inspection.group?.previewLabel == "Previewing item 2 of 2")
        browser.openMenu(.actions)
        let actions = Set(browser.availableActions.map(\.id))
        #expect(Set(["copy", "paste", "share", "save", "chat", "quickLook"]).isSubset(of: actions))
        #expect(Set(["edit", "snippet", "plain", "annotate"]).isDisjoint(with: actions))
        browser.beginEdit(.edit)
        #expect(browser.editor == nil)

        let texts = ClipboardGroupSummary([.content(.text("a")), .content(.text("b"))])
        #expect(texts?.previewLabel == "Combined text from 2 items")
        #expect(texts?.previewsOneItem == false)
        let url = URL(fileURLWithPath: "/tmp/fixture.pdf")
        let files = ClipboardGroupSummary([.content(.files([url])), .content(.files([url]))])
        #expect(files?.previewLabel == "2 files")
        #expect(files?.canAnnotate == true)
        let images = ClipboardGroupSummary([.content(.image(Data())), .content(.image(Data()))])
        #expect(images?.previewLabel == "Previewing item 1 of 2")
        #expect(images?.imageCount == 2)
    }

}
