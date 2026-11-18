import ShadShell
import ShadMouseFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(MouseModule.definition))
    }
}
