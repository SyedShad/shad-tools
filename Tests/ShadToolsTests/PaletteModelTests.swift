import AppKit
import Testing
@testable import ShadCore
@testable import ShadShell
@testable import ShadColorFeature

@Suite("Palette actions", .serialized) @MainActor
struct PaletteModelTests {
    @Test func actionSearchPreservesCommandQueryAndSelection() throws {
        let prefs = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = PaletteModel(.standalone(ColorModule.definition), preferences: prefs)
        model.query = "pick"
        let original = try #require(model.current?.id)
        model.toggleActions()
        model.actionQuery = "short"
        #expect(model.filteredActions == [.shortcut])
        model.confirmSelection()
        #expect(model.recording == original)
        #expect(model.actionTarget == nil)
        model.back()
        #expect(model.query == "pick")
        #expect(model.current?.id == original)
        model.toggleActions()
        model.actionQuery = "nothing matches"
        model.confirmSelection()
        #expect(model.actionTarget == original)
        model.back()
        #expect(model.actionTarget == nil)
        #expect(model.query == "pick")
    }

    @Test func favoritesPersistAndAppearOnceOnTheToolHome() throws {
        let name = UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let model = PaletteModel(.standalone(ColorModule.definition), preferences: prefs)
        model.move(1)
        let id = try #require(model.current?.id)
        model.toggleActions()
        model.performAction(.favorite)
        #expect(model.rows.first?.id == id)
        #expect(model.sectionHeaders[id] == "Favorites")
        #expect(model.rows.filter { $0.id == id }.count == 1)
        let reopened = PaletteModel(.standalone(ColorModule.definition), preferences: prefs)
        #expect(reopened.favorites == [id])
        reopened.toggleActions()
        reopened.performAction(.favorite)
        #expect(reopened.favorites.isEmpty)
    }

    @Test func appearanceDefaultsToSystemAndRemembersExplicitSelection() throws {
        let name = UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let model = PaletteModel(.standalone(ColorModule.definition), preferences: prefs)
        #expect(model.appearance == .system)
        model.appearance = .light
        #expect(PaletteModel(.standalone(ColorModule.definition), preferences: prefs).appearance == .light)
    }

    @Test func closingThePaletteClearsActionAndRecorderModes() throws {
        let model = PaletteModel(.standalone(ColorModule.definition), preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
        model.toggleActions()
        #expect(model.actionTarget != nil)
        model.closed()
        #expect(model.actionTarget == nil)
        model.toggleActions()
        model.performAction(.shortcut)
        #expect(model.recording != nil)
        model.closed()
        #expect(model.recording == nil)
    }

    @Test func featureNamespacesIsolateCommandsDespiteMatchingDisplayGroups() throws {
        func module(_ id: String, commandIDs: [String]) -> FeatureModule {
            FeatureModule(id: id, appName: id, category: id, group: "Shared display name",
                          detail: "", symbol: "command") {
                FeatureSession(commands: {
                    commandIDs.map { commandID in
                        ToolCommand(id: commandID, title: commandID, subtitle: "", symbol: "command",
                                    group: "Shared display name", perform: {})
                    }
                })
            }
        }
        let first = module("first", commandIDs: ["first.original"])
        let second = module("second", commandIDs: ["first.original", "app.open", "second.new", "second.new"])
        let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = PaletteModel(.suite([first, second]), preferences: preferences)
        model.selectScope(second)
        #expect(model.rows.map(\.id) == ["second.new"])
        model.selectScope(first)
        #expect(model.rows.map(\.id) == ["first.original"])
    }
}
