import ShadShell
import ShadSearchFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(SearchModule.definition))
    }
}
