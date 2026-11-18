import ShadShell
import ShadCaptureFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(CaptureModule.definition))
    }
}
