import Foundation

enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case image(Data) // Canonical PNG, including alpha.
    case files([URL])
}

struct ClipboardRepresentation: Codable, Equatable, Sendable {
    let type: String
    let data: Data
}

struct ClipboardCapture: Equatable, Sendable {
    let content: ClipboardContent
    var items: [[ClipboardRepresentation]] = []
    var sourceBundleID: String? = nil
    var sourceName: String? = nil
    // Used until commit to recheck exclusions if another edition changes them during the copy.
    var observedBundleIDs: [String] = []
}

enum ClipboardKind: String, Codable, Sendable {
    case text, image, files, link, email, color

    static func classify(_ text: String) -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192 else { return .text }
        if ClipboardColor(css: value) != nil { return .color }
        if value.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil { return .email }
        if !value.contains(where: \.isWhitespace), let url = URL(string: value),
           let scheme = url.scheme?.lowercased(), ["https", "http", "ftp"].contains(scheme),
           url.host?.isEmpty == false { return .link }
        return .text
    }
}

struct ClipboardEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ClipboardKind
    let title: String
    let copiedAt: Date
    let byteCount: Int
    var thumbnail: Data? = nil
    var firstCopiedAt: Date = .distantPast
    var copyCount = 1
    var sourceBundleID: String? = nil
    var sourceName: String? = nil
    var isPinned = false
    var isSnippet = false
    var formatTypes: [String] = []
    var itemCount = 1
    var recognizedText: String? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
}
