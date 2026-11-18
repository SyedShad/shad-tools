import AppKit

package struct ToolAction: Identifiable, Hashable {
    package let id: String
    package let title: String
    package let symbol: String
    package let perform: @MainActor () -> Void

    package init(id: String, title: String, symbol: String, perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.perform = perform
    }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    package func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

package struct ToolCommand: Identifiable {
    package let id: String
    package let title: String
    package let subtitle: String
    package let symbol: String
    package let group: String
    package let fileURL: URL?
    package let swatch: NSColor?
    package let actions: [ToolAction]
    package var keywords: String
    package let perform: @MainActor () -> Void

    package init(id: String, title: String, subtitle: String, symbol: String, group: String,
                 keywords: String = "", fileURL: URL? = nil, swatch: NSColor? = nil, actions: [ToolAction] = [],
                 perform: @escaping @MainActor () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.group = group
        self.keywords = keywords
        self.fileURL = fileURL
        self.swatch = swatch
        self.actions = actions
        self.perform = perform
    }
}

@MainActor package enum Commands {
    package static var onChange: (() -> Void)?
    package static func changed() { onChange?() }
}

@MainActor package enum Feedback {
    package static var present: ((String) -> Void)?
    package static func show(_ message: String) {
        present?(message)
    }
}

@MainActor package enum TargetApplication {
    package static var previous: NSRunningApplication?
    package static var current: NSRunningApplication? {
        let active = NSWorkspace.shared.frontmostApplication
        return active?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? previous : active ?? previous
    }

    package static func capture() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous = app
        }
    }
}
