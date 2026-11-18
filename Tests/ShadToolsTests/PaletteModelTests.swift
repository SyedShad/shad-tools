import AppKit
import Testing
@testable import ShadTools

@Suite("Palette actions", .serialized) @MainActor
struct PaletteModelTests {
    @Test func actionSearchPreservesCommandQueryAndSelection() throws {
        let prefs = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = PaletteModel(.color, preferences: prefs)
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
        let model = PaletteModel(.color, preferences: prefs)
        model.move(1)
        let id = try #require(model.current?.id)
        model.toggleActions()
        model.performAction(.favorite)
        #expect(model.rows.first?.id == id)
        #expect(model.sectionHeaders[id] == "Favorites")
        #expect(model.rows.filter { $0.id == id }.count == 1)
        let reopened = PaletteModel(.color, preferences: prefs)
        #expect(reopened.favorites == [id])
        reopened.toggleActions()
        reopened.performAction(.favorite)
        #expect(reopened.favorites.isEmpty)
    }

    @Test func appearanceDefaultsToSystemAndRemembersExplicitSelection() throws {
        let name = UUID().uuidString
        let prefs = try #require(UserDefaults(suiteName: name))
        defer { prefs.removePersistentDomain(forName: name) }
        let model = PaletteModel(.color, preferences: prefs)
        #expect(model.appearance == .system)
        model.appearance = .light
        #expect(PaletteModel(.color, preferences: prefs).appearance == .light)
    }

    @Test func closingThePaletteClearsActionAndRecorderModes() throws {
        let model = PaletteModel(.color, preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
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
}
