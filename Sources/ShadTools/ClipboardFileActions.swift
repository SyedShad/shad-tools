import AppKit
import CryptoKit
import Quartz
import UniformTypeIdentifiers

@MainActor
final class ClipboardFileActions: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    enum Action { case save, open, openWith, annotate, reveal, quickLook }
    private var previewURLs: [URL] = []
    private var sharePicker: NSSharingServicePicker?
    private let workspace = NSWorkspace.shared

    func run(_ action: Action, on entry: ClipboardEntry, content: ClipboardContent) async {
        do {
            if action == .save {
                try await export(entry: entry, content: content)
                return
            }
            if action == .open, case .text(let text) = content {
                let url: URL?
                switch entry.kind {
                case .link:
                    let candidate = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                    url = ["http", "https", "ftp"].contains(candidate?.scheme?.lowercased() ?? "") ? candidate : nil
                case .email:
                    var components = URLComponents()
                    components.scheme = "mailto"
                    components.path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    url = components.url
                default: url = nil
                }
                if let url {
                    guard workspace.open(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
                    return
                }
            }
            let urls = try await fileURLs(for: entry, content: content, action: action)
            guard !urls.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            switch action {
            case .reveal: workspace.activateFileViewerSelecting(urls)
            case .quickLook:
                guard let panel = QLPreviewPanel.shared() else { throw CocoaError(.featureUnsupported) }
                previewURLs = urls
                panel.dataSource = self
                panel.delegate = self
                panel.currentPreviewItemIndex = 0
                panel.reloadData()
                panel.makeKeyAndOrderFront(nil)
                panel.orderFrontRegardless()
            case .openWith:
                let chooser = NSOpenPanel()
                chooser.title = "Open With"
                chooser.prompt = "Open"
                chooser.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                chooser.allowedContentTypes = [.applicationBundle]
                guard await chooser.begin() == .OK, let appURL = chooser.url else { return }
                _ = try await workspace.open(urls, withApplicationAt: appURL, configuration: .init())
            case .annotate:
                guard let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try await workspace.open(urls, withApplicationAt: preview, configuration: .init())
                Feedback.show("Use Show Markup Toolbar in Preview to annotate. Save your changes in Preview.")
            case .open:
                for url in urls where !workspace.open(url) { throw CocoaError(.fileReadUnknown) }
            case .save: break
            }
        } catch { Feedback.show(error.localizedDescription) }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil }
    }

    func share(_ content: ClipboardContent, from anchor: NSView) {
        let items: [Any]
        switch content {
        case .text(let text): items = [text]
        case .image(let data):
            guard let image = NSImage(data: data) else { Feedback.show("Couldn’t read this image."); return }
            items = [image]
        case .files(let urls): items = urls
        }
        let picker = NSSharingServicePicker(items: items)
        sharePicker = picker
        let rect = NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }

    /// Finder, Preview and other apps require real filesystem URLs. Each retained
    /// history ID gets a reusable temporary file. Finder file references stay intact.
    private func fileURLs(for entry: ClipboardEntry, content: ClipboardContent, action: Action) async throws -> [URL] {
        if case .files(let urls) = content {
            for url in urls where !url.isFileURL || !FileManager.default.fileExists(atPath: url.path) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url])
            }
            return urls
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shad Clipboard Exports", isDirectory: true)
        return try await Task.detached(priority: .userInitiated) {
            [try Self.materialize(entry: entry, content: content, action: action, root: root)]
        }.value
    }

    nonisolated static func materialize(entry: ClipboardEntry, content: ClipboardContent, action: Action, root: URL) throws -> URL {
        let data: Data
        switch content {
        case .image(let bytes): data = bytes
        case .text(let text): data = Data(text.utf8)
        case .files: throw CocoaError(.fileReadUnsupportedScheme)
        }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent(fingerprint, isDirectory: true)
        let manager = FileManager.default
        let markup = folder.appendingPathComponent("Markup.png")
        let url: URL
        if case .image = content, action == .annotate || (action == .reveal && manager.fileExists(atPath: markup.path)) { url = markup }
        else { url = folder.appendingPathComponent("Original", isDirectory: true).appendingPathComponent(filename(for: entry, content: content)) }
        if manager.fileExists(atPath: url.path) { return url }
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent("." + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging)
        // Atomically publish the complete file. Never overwrite a user's saved annotations.
        if link(staging.path, url.path) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    nonisolated static func checkCopyDestination(source: URL, destination: URL) throws {
        guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { return }
        let src = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dst = destination.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if dst.starts(with: src) { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "Choose a destination outside the folder being copied."]) }
    }

    nonisolated private static func safeFilename(_ text: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        var name = text.components(separatedBy: disallowed).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.first == "." { name.removeFirst() }
        return String((name.isEmpty ? "Clipboard Entry" : name).prefix(85))
    }

    nonisolated private static func filename(for entry: ClipboardEntry, content: ClipboardContent) -> String {
        let name = safeFilename(entry.title)
        switch content {
        case .text: return name.lowercased().hasSuffix(".txt") ? name : name + ".txt"
        case .image: return name.lowercased().hasSuffix(".png") ? name : name + ".png"
        case .files(let urls): return urls.first?.lastPathComponent ?? name
        }
    }

    private func export(entry: ClipboardEntry, content: ClipboardContent) async throws {
        if case .files(let urls) = content, urls.count > 1 {
            let chooser = NSOpenPanel()
            chooser.title = "Save Copied Files"
            chooser.prompt = "Save Here"
            chooser.canChooseDirectories = true
            chooser.canChooseFiles = false
            chooser.canCreateDirectories = true
            guard await chooser.begin() == .OK, let directory = chooser.url else { return }
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for url in urls { try Self.checkCopyDestination(source: url, destination: directory) }
                let staging = directory.appendingPathComponent(".shad-export-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: staging) }
                for (index, url) in urls.enumerated() {
                    try fm.copyItem(at: url, to: staging.appendingPathComponent(String(index)))
                }
                for (index, url) in urls.enumerated() {
                    let filename = url.lastPathComponent
                    var dest = directory.appendingPathComponent(filename)
                    var number = 2
                    while fm.fileExists(atPath: dest.path) {
                        let base = (filename as NSString).deletingPathExtension
                        let ext = (filename as NSString).pathExtension
                        dest = directory.appendingPathComponent(base + " " + String(number) + (ext.isEmpty ? "" : "." + ext))
                        number += 1
                    }
                    try fm.moveItem(at: staging.appendingPathComponent(String(index)), to: dest)
                }
            }.value
            return
        }
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = Self.filename(for: entry, content: content)
        if case .image = content { chooser.allowedContentTypes = [.png] }
        if case .text = content { chooser.allowedContentTypes = [.plainText] }
        chooser.canCreateDirectories = true
        guard await chooser.begin() == .OK, let url = chooser.url else { return }
        try await Task.detached(priority: .userInitiated) {
            switch content {
            case .image(let data): try data.write(to: url, options: .atomic)
            case .text(let text): try text.write(to: url, atomically: true, encoding: .utf8)
            case .files(let urls):
                guard let source = urls.first else { throw CocoaError(.fileNoSuchFile) }
                if source.standardizedFileURL == url.standardizedFileURL { return }
                try Self.checkCopyDestination(source: source, destination: url)
                let manager = FileManager.default
                let staging = url.deletingLastPathComponent().appendingPathComponent(".shad-copy-" + UUID().uuidString)
                defer { try? manager.removeItem(at: staging) }
                try manager.copyItem(at: source, to: staging)
                if manager.fileExists(atPath: url.path) { _ = try manager.replaceItemAt(url, withItemAt: staging) }
                else { try manager.moveItem(at: staging, to: url) }
            }
        }.value
    }
}
