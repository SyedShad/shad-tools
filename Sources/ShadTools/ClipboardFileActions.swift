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

    nonisolated private static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Shad Clipboard Exports", isDirectory: true)

    func run(_ action: Action, on entry: ClipboardEntry, capture: ClipboardCapture) async {
        do {
            let contents = try await Task.detached(priority: .userInitiated) {
                try Self.contents(of: capture)
            }.value
            if action == .save {
                try await export(entry: entry, contents: contents)
                return
            }
            if action == .open, contents.count == 1, case .text(let text) = contents[0], let url = Self.link(in: text) {
                guard workspace.open(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
                return
            }
            let urls = try await Task.detached(priority: .userInitiated) {
                try Self.fileURLs(for: entry, contents: contents, action: action)
            }.value
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

    nonisolated static func contents(of capture: ClipboardCapture, root: URL? = nil) throws -> [ClipboardContent] {
        let members = ClipboardPasteboard.members(of: capture)
        guard !members.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return try members.map { member in
            switch member {
            case .content(let content): return content
            case .representation(let rep):
                // Preserve an app-specific item even when no visual preview exists.
                let folder = (root ?? temporaryRoot).appendingPathComponent(digest(rep.data), isDirectory: true)
                let url = folder.appendingPathComponent(safeFilename(rep.type) + ".bin")
                try publish(rep.data, at: url)
                return .files([url])
            }
        }
    }

    nonisolated private static func link(in text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch ClipboardKind.classify(value) {
        case .link: return URL(string: value)
        case .email:
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = value
            return components.url
        default: return nil
        }
    }

    static func sharingItems(for contents: [ClipboardContent]) throws -> [Any] {
        var items: [Any] = []
        for content in contents {
            switch content {
            case .text(let text):
                if let link = Self.link(in: text) { items.append(link) } else { items.append(text) }
            case .image(let data):
                guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                items.append(image)
            case .files(let urls): items.append(contentsOf: urls)
            }
        }
        return items
    }

    func share(_ capture: ClipboardCapture, from anchor: NSView) async {
        do {
            let contents = try await Task.detached(priority: .userInitiated) { try Self.contents(of: capture) }.value
            let items = try Self.sharingItems(for: contents)
            guard anchor.window?.isVisible == true else { return }
            let picker = NSSharingServicePicker(items: items)
            sharePicker = picker
            let rect = NSRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
            picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        } catch { Feedback.show(error.localizedDescription) }
    }

    nonisolated static func fileURLs(for entry: ClipboardEntry, contents: [ClipboardContent], action: Action, root: URL? = nil) throws -> [URL] {
        let root = root ?? temporaryRoot
        return try contents.enumerated().flatMap { index, content -> [URL] in
            if case .files(let urls) = content {
                for url in urls where !url.isFileURL || !FileManager.default.fileExists(atPath: url.path) {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: url])
                }
                return urls
            }
            let name = contents.count > 1 ? "Clipboard item " + String(index + 1) : nil
            return [try materialize(entry: entry, content: content, action: action, root: root, name: name)]
        }
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func materialize(entry: ClipboardEntry, content: ClipboardContent, action: Action, root: URL, name: String? = nil) throws -> URL {
        let data: Data
        switch content {
        case .image(let bytes): data = bytes
        case .text(let text): data = Data(text.utf8)
        case .files: throw CocoaError(.fileReadUnsupportedScheme)
        }
        let folder = root.appendingPathComponent(digest(data), isDirectory: true)
        let manager = FileManager.default
        let markup = folder.appendingPathComponent("Markup.png")
        let url: URL
        if case .image = content, action == .annotate || (action == .reveal && manager.fileExists(atPath: markup.path)) { url = markup }
        else { url = folder.appendingPathComponent("Original", isDirectory: true).appendingPathComponent(filename(title: name ?? entry.title, content: content)) }
        try publish(data, at: url)
        return url
    }

    nonisolated private static func publish(_ data: Data, at url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return }
        let parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent("." + UUID().uuidString)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging)
        // Atomically publish the complete file. Never overwrite a user's saved annotations.
        if Darwin.link(staging.path, url.path) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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

    nonisolated private static func filename(title: String, content: ClipboardContent) -> String {
        let name = safeFilename(title)
        switch content {
        case .text: return name.lowercased().hasSuffix(".txt") ? name : name + ".txt"
        case .image: return name.lowercased().hasSuffix(".png") ? name : name + ".png"
        case .files(let urls): return urls.first?.lastPathComponent ?? name
        }
    }

    nonisolated static func exportGroup(_ urls: [URL], into directory: URL) throws {
        let fm = FileManager.default
        for url in urls { try checkCopyDestination(source: url, destination: directory) }
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
    }

    private func export(entry: ClipboardEntry, contents: [ClipboardContent]) async throws {
        guard let content = contents.first else { throw CocoaError(.fileReadCorruptFile) }
        if contents.count > 1 {
            let chooser = NSOpenPanel()
            chooser.title = "Save Copied Items"
            chooser.prompt = "Save Here"
            chooser.canChooseDirectories = true
            chooser.canChooseFiles = false
            chooser.canCreateDirectories = true
            guard await chooser.begin() == .OK, let directory = chooser.url else { return }
            try await Task.detached(priority: .userInitiated) {
                let urls = try Self.fileURLs(for: entry, contents: contents, action: .save)
                try Self.exportGroup(urls, into: directory)
            }.value
            return
        }
        let chooser = NSSavePanel()
        chooser.nameFieldStringValue = Self.filename(title: entry.title, content: content)
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
