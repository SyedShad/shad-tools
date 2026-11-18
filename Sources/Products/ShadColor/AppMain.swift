import ShadShell
import ShadColorFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(ColorModule.definition))
    }
}
