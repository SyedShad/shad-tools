import AppKit

struct ToolCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let group: String
    var keywords: String = ""
    let perform: @MainActor () -> Void
}

@MainActor enum Commands {
    static var onChange: (() -> Void)?
    static func changed() { onChange?() }
}

@MainActor enum Feedback {
    static var present: ((String) -> Void)?
    static func show(_ message: String) {
        present?(message)
    }
}

@MainActor enum TargetApplication {
    static var previous: NSRunningApplication?
    static var current: NSRunningApplication? {
        let active = NSWorkspace.shared.frontmostApplication
        return active?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : active ?? previous
    }

    static func capture() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous = app
        }
    }
}

enum Edition: String, CaseIterable {
    case suite, search, audio, drives, color, windows, capture
    static var current: Edition {
        let key = Bundle.main.object(forInfoDictionaryKey: "ShadEdition") as? String
        return Edition(rawValue: key ?? "suite") ?? .suite
    }
    var title: String {
        switch self {
        case .suite: return "Shad Tools"
        case .search: return "Shad Search"
        case .audio: return "Shad Audio"
        case .drives: return "Shad Eject"
        case .color: return "Shad Color"
        case .windows: return "Shad Windows"
        case .capture: return "Shad Capture"
        }
    }
    var group: String {
        switch self {
        case .suite: return "All tools"
        case .search: return "Search"
        case .audio: return "Audio"
        case .drives: return "Drives"
        case .color: return "Color"
        case .windows: return "Windows"
        case .capture: return "Capture"
        }
    }
    var category: String {
        switch self {
        case .suite: return title
        case .search: return "Search Mac"
        case .audio: return "Audio Manager"
        case .drives: return "Easy Eject"
        case .color: return "Color Picker"
        case .windows: return "Window Layouts"
        case .capture: return "Screen Capture"
        }
    }
    var detail: String {
        switch self {
        case .suite: return ""
        case .search: return "Applications, files and folders"
        case .audio: return "Rank input and output devices independently"
        case .drives: return "Safely eject external drives"
        case .color: return "Sample a pixel and copy its color"
        case .windows: return "Tile windows and link their edges"
        case .capture: return "Take screenshots and record your screen with a camera overlay"
        }
    }
    var symbol: String {
        switch self {
        case .suite: return "square.stack.3d.up.fill"
        case .search: return "magnifyingglass"
        case .audio: return "waveform"
        case .drives: return "eject.fill"
        case .color: return "eyedropper"
        case .windows: return "rectangle.split.2x1"
        case .capture: return "camera.viewfinder"
        }
    }
    var includesSearch: Bool { self == .suite || self == .search }
}
