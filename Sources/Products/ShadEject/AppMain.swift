import ShadShell
import ShadDrivesFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(DrivesModule.definition))
    }
}
