import AppKit

struct SearchItem: Equatable, Sendable {
    enum Kind: Sendable { case application, folder, file }
    let url: URL
    let title: String
    let kind: Kind

    @MainActor
    func command(keywords: String = "") -> ToolCommand {
        let path = url.path
        let icon: String
        switch kind {
        case .application: icon = "app"
        case .folder: icon = "folder"
        case .file: icon = "doc"
        }
        let pathLabel = (path as NSString).abbreviatingWithTildeInPath
        return ToolCommand(
            id: "search.\(kind == .application ? "app" : "file").\(path)",
            title: title, subtitle: pathLabel, symbol: icon,
            group: kind == .application ? "Apps" : "Files", keywords: keywords
        ) {
            if !NSWorkspace.shared.open(url) {
                Feedback.show("Couldn’t open \(title). Check that it’s still available.")
            }
        }
    }
}

enum ApplicationCatalog {
    static func scan(roots: [URL]) -> [SearchItem] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .localizedNameKey]
        var seen = Set<URL>()
        var apps: [SearchItem] = []
        for root in roots {
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                  errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker {
                if url.pathExtension.lowercased() == "app" {
                    walker.skipDescendants()
                    guard manager.fileExists(atPath: url.path),
                          seen.insert(url.resolvingSymlinksInPath()).inserted else { continue }
                    let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
                    let title = name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
                    apps.append(SearchItem(url: url, title: title, kind: .application))
                } else if walker.level >= 3 {
                    walker.skipDescendants()
                }
            }
        }
        return apps.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    static func installed() -> [SearchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
                     home.appendingPathComponent("Applications", isDirectory: true)]
        var apps = scan(roots: roots)
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: finder.path) {
            apps.append(SearchItem(url: finder, title: "Finder", kind: .application))
        }
        return apps
    }
}

@MainActor
final class SearchTool: NSObject {
    private var apps: [ToolCommand] = []
    private var files: [SearchItem] = []
    private var catalogUpdated = Date.distantPast
    private var refreshing = false
    private var requestedText = ""
    private var pending: Task<Void, Never>?
    private var metadata: NSMetadataQuery?

    override init() {
        super.init()
        refreshAppsIfNeeded()
    }

    func commands() -> [ToolCommand] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let locations: [(String, String, URL, String)] = [
            ("home", "Home Folder", home, "house"),
            ("downloads", "Downloads", home.appendingPathComponent("Downloads", isDirectory: true), "arrow.down.circle"),
            ("applications", "Applications Folder", URL(fileURLWithPath: "/Applications", isDirectory: true), "square.grid.2x2")
        ]
        return locations.map { id, name, url, icon in
            ToolCommand(id: "search.location.\(id)", title: "Open \(name)",
                        subtitle: "Show in Finder", symbol: icon, group: "Search", keywords: "browse location folder") {
                if !NSWorkspace.shared.open(url) { Feedback.show("Couldn’t open \(name).") }
            }
        }
    }

    func results(for query: String) -> [ToolCommand] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshAppsIfNeeded()
        if requestedText != text {
            requestedText = text
            pending?.cancel()
            stopMetadata()
            files = []
            if text.hasPrefix("/") || text.hasPrefix("~/") || text == "~" {
                pending = Task { [weak self] in
                    let result = await Task.detached(priority: .userInitiated) {
                        Self.itemAtPath(text)
                    }.value
                    guard !Task.isCancelled, let self, self.requestedText == text, let result else { return }
                    self.files = [result]
                    Commands.changed()
                }
            } else if text.count >= 2 {
                pending = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    guard !Task.isCancelled, self?.requestedText == text else { return }
                    self?.startMetadata(text)
                }
            }
        }
        guard !text.isEmpty else { return [] }
        // A path match takes precedence over a candidate that mentions the same path.
        let dynamic = files.map { $0.command(keywords: text) }
        if files.first?.kind == .application, let directID = dynamic.first?.id {
            return dynamic + apps.filter { $0.id != directID }
        }
        return dynamic + apps
    }

    nonisolated static func itemAtPath(_ text: String) -> SearchItem? {
        guard text.hasPrefix("/") || text.hasPrefix("~/") || text == "~" else { return nil }
        let path = (text as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue).standardizedFileURL
        let kind: SearchItem.Kind = url.pathExtension.lowercased() == "app" ? .application : isDirectory.boolValue ? .folder : .file
        let title = kind == .application ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        return SearchItem(url: url, title: title, kind: kind)
    }

    private func refreshAppsIfNeeded() {
        guard !refreshing, Date().timeIntervalSince(catalogUpdated) >= 60 else { return }
        refreshing = true
        Task { [weak self] in
            let items = await Task.detached(priority: .utility) { ApplicationCatalog.installed() }.value
            guard let self else { return }
            apps = items.map { $0.command() }
            catalogUpdated = Date()
            refreshing = false
            Commands.changed()
        }
    }

    nonisolated static func filePredicate(_ text: String) -> NSPredicate? {
        // Treat Spotlight wildcards as separators. Predicate arguments remain literal data.
        let terms = text.split { $0.isWhitespace || "*?\\".contains($0) }
        let predicates = terms.prefix(12).map {
            NSPredicate(format: "%K LIKE[cd] %@", "kMDItemFSName", "*\($0)*")
        }
        guard let first = predicates.first else { return nil }
        // Spotlight rejects AND predicates with only one child.
        return predicates.count == 1 ? first : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    private func startMetadata(_ text: String) {
        guard let predicate = Self.filePredicate(text) else { return }
        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = predicate
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        NotificationCenter.default.addObserver(self, selector: #selector(didGather(_:)),
                                               name: .NSMetadataQueryDidFinishGathering, object: query)
        metadata = query
        if !query.start() { stopMetadata() }
    }

    @objc private func didGather(_ note: Notification) {
        guard let query = note.object as? NSMetadataQuery, metadata === query else { return }
        query.disableUpdates()
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        var items: [SearchItem] = []
        for index in 0..<min(320, query.resultCount) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String, path.hasPrefix(home) else { continue }
            let relative = path.dropFirst(home.count)
            guard !relative.hasPrefix("Library/"),
                  !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }),
                  !relative.lowercased().hasSuffix(".app"), !relative.lowercased().contains(".app/") else { continue }
            let typeTree = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
            let isFolder = typeTree.contains("public.folder")
            let url = URL(fileURLWithPath: path, isDirectory: isFolder)
            items.append(SearchItem(url: url, title: url.lastPathComponent, kind: isFolder ? .folder : .file))
            if items.count == 30 { break }
        }
        query.enableUpdates()
        stopMetadata()
        if files != items {
            files = items
            Commands.changed()
        }
    }

    private func stopMetadata() {
        guard let metadata else { return }
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: metadata)
        if metadata.isStarted && !metadata.isStopped { metadata.stop() }
        self.metadata = nil
    }
}
