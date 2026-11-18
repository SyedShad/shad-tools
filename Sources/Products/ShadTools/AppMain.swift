import ShadShell
import ShadSearchFeature
import ShadAudioFeature
import ShadDrivesFeature
import ShadColorFeature
import ShadWindowsFeature
import ShadCaptureFeature
import ShadClipboardFeature
import ShadMouseFeature

@main enum AppMain {
    @MainActor static func main() {
        ShadApplication.run(.suite([
            SearchModule.definition,
            AudioModule.definition,
            DrivesModule.definition,
            ColorModule.definition,
            WindowsModule.definition,
            CaptureModule.definition,
            ClipboardModule.definition,
            MouseModule.definition,
        ]))
    }
}
