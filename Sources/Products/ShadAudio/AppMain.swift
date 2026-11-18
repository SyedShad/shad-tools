import ShadShell
import ShadAudioFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.standalone(AudioModule.definition))
    }
}
