import Foundation
import Testing
@testable import ShadTools

@Suite("Launcher search")
struct SearchTests {
    @MainActor
    private func command(_ title: String, keywords: String = "") -> ToolCommand {
        ToolCommand(id: title, title: title, subtitle: "", symbol: "", group: "Tools",
                    keywords: keywords, perform: {})
    }

    @Test @MainActor
    func prefersExactMatchesAndPreservesTies() {
        let commands = [command("Safari Technology Preview"), command("Open Safari"), command("Safari")]
        #expect(rankedCommands(commands, query: " safari ").map(\.title) ==
                ["Safari", "Safari Technology Preview", "Open Safari"])
        #expect(rankedCommands(commands, query: "").map(\.title) == commands.map(\.title))
        let tied = [command("Launch Downloads"), command("Launch Documents")]
        #expect(rankedCommands(tied, query: "launch").map(\.title) == tied.map(\.title))
    }

    @Test @MainActor
    func supportsFuzzyAppsInitialsAccentsAndAliases() {
        let commands = [command("Messages"), command("System Settings"), command("Café"),
                        command("Configure Speakers", keywords: "sound audio device")]
        for (query, expected) in [("msg", "Messages"), ("ss", "System Settings"), ("CAFE", "Café"),
                                  ("audio", "Configure Speakers"), ("audio speak", "Configure Speakers")] {
            #expect(rankedCommands(commands, query: query).first?.title == expected)
        }
        #expect(rankedCommands(commands, query: "unrelated").isEmpty)
    }

    @Test @MainActor
    func spotlightAcceptsSingleAndMultipleLiteralTerms() {
        for term in ["draft", "sample notes.txt", "Brad's report [1]", "100% done"] {
            let query = NSMetadataQuery()
            query.predicate = SearchTool.filePredicate(term)
            #expect(query.predicate != nil)
        }
        #expect(SearchTool.filePredicate("?*") == nil)
    }

    @Test
    func catalogsNestedAppsOnceAndSkipsTheirContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let actual = root.appendingPathComponent("Utilities/Example.app", isDirectory: true)
        try manager.createDirectory(at: actual.appendingPathComponent("Contents/Helper.app"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: root.appendingPathComponent("Example.app"), withDestinationURL: actual)
        let found = ApplicationCatalog.scan(roots: [root, root])
        #expect(found.count == 1)
        #expect(found.first?.title == "Example")
        #expect(found.first?.url.resolvingSymlinksInPath() == actual.resolvingSymlinksInPath())
    }

    @Test
    func resolvesExistingLiteralPathsOnly() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("A [draft]'s notes.md")
        try Data().write(to: file)
        #expect(SearchTool.itemAtPath(file.path)?.title == file.lastPathComponent)
        #expect(SearchTool.itemAtPath(root.path)?.kind == .folder)
        #expect(SearchTool.itemAtPath("~")?.kind == .folder)
        #expect(SearchTool.itemAtPath("relative/file.txt") == nil)
        #expect(SearchTool.itemAtPath(file.path + ".missing") == nil)
    }
}
