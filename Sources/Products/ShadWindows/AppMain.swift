import ShadShell
import ShadWindowsFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(WindowsModule.definition))
    }
}
