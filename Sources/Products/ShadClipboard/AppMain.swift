import ShadShell
import ShadClipboardFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(ClipboardModule.definition))
    }
}
