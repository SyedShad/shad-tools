import ShadCore
import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

@MainActor final class ClipboardTool: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var snippets: [ClipboardEntry] = []
    @Published private(set) var paused = false
    @Published private(set) var privacy = ClipboardPrivacy()
    @Published private(set) var issue: String?
    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let worker = DispatchQueue(label: "io.github.syedshad.shadtools.clipboard", qos: .userInitiated)
    private let instance = UUID().uuidString
    private static let changes = Notification.Name("io.github.syedshad.shadtools.clipboard.changed")
    private var observer: NSObjectProtocol?
    private var monitor: Task<Void, Never>?
    private var imageIndexing: Task<Void, Never>?
    private var attemptedOCR = Set<String>()
    private let fileActions = ClipboardFileActions()
    var pasteTargetName: String? { pasteTarget?.localizedName }
    private var revision = 0
    private var emptyRetries = 0
    private static let bootSession: String = {
        var value = [CChar](repeating: 0, count: 64)
        var size = value.count
        if sysctlbyname("kern.bootsessionuuid", &value, &size, nil, 0) == 0 { return String(cString: value) }
        var boot = timeval()
        size = MemoryLayout.size(ofValue: boot)
        _ = sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return String(boot.tv_sec)
    }()
    private var lastChange: Int
    private var pasteTarget: NSRunningApplication?
    private lazy var window = ClipboardHistoryWindow(tool: self)

    convenience init() {
        self.init(store: ClipboardStore(), pasteboard: .general)
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("Shad Clipboard Exports")
        Task {
            do { try await perform { try $0.migratePreviewCopies(from: legacy) } }
            catch { Feedback.show("Couldn’t finish moving earlier clipboard working copies. Reopen Shad to retry.") }
        }
    }

    init(store: ClipboardStore, pasteboard: NSPasteboard, monitor: Bool = true) {
        self.store = store
        self.pasteboard = pasteboard
        // The contents that predate launch were never copied while history was running.
        lastChange = pasteboard.changeCount
        guard monitor else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.changes, object: nil, queue: .main) { [weak self] note in
            let origin = note.object as? String
            Task { @MainActor in
                guard let self, origin != self.instance else { return }
                await self.synchronize()
            }
        }
        self.monitor = Task { [weak self] in
            await self?.synchronize()
            var nextExpiryCheck = Date().addingTimeInterval(60)
            while !Task.isCancelled {
                guard self != nil else { return }
                if Date() >= nextExpiryCheck {
                    if let self, self.privacy.retention != .noAgeLimit { await self.synchronize() }
                    nextExpiryCheck = Date().addingTimeInterval(60)
                }
                await self?.poll()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    deinit {
        monitor?.cancel()
        imageIndexing?.cancel()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func perform<T>(_ operation: @escaping @Sendable (ClipboardStore) throws -> T) async throws -> T {
        let store = self.store
        return try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try operation(store) }) }
        }
    }

    private var accessIssue: String? {
        if #available(macOS 15.4, *), pasteboard.name == .general {
            switch pasteboard.accessBehavior {
            case .ask, .alwaysDeny:
                return "Choose Always Allow for this app’s clipboard access in System Settings to record new copies."
            default: break
            }
        }
        return nil
    }

    func synchronize() async {
        revision &+= 1
        let requested = revision
        do {
            let (rows, savedSnippets, isPaused, settings) = try await perform { store in
                (try store.entries(), try store.snippets(), try store.isPaused(), try store.privacySettings())
            }
            guard requested == revision else { return }
            if isPaused != paused { lastChange = pasteboard.changeCount; paused = isPaused }
            if entries != rows { entries = rows }
            if snippets != savedSnippets { snippets = savedSnippets }
            if privacy != settings { privacy = settings }
            indexImagesIfNeeded()
            issue = paused ? nil : accessIssue
        } catch { issue = "Clipboard history storage is unavailable. Check your available disk space and reopen the window." }
    }

    func poll(frontmostBundleID: String? = nil) async {
        let count = pasteboard.changeCount
        if count != lastChange {
            lastChange = count
            emptyRetries = 4
        } else if emptyRetries == 0 { return }
        emptyRetries -= 1
        guard !paused else { emptyRetries = 0; return }
        if let accessIssue { emptyRetries = 0; issue = accessIssue; return }
        let name = pasteboard.name.rawValue
        let app = pasteboard.name == .general ? NSWorkspace.shared.frontmostApplication : nil
        let front = frontmostBundleID ?? app?.bundleIdentifier
        let frontName = front == app?.bundleIdentifier ? app?.localizedName : nil
        let now = Date()
        let generation = Self.bootSession + "." + name + "." + String(count)
        do {
            let (changed, empty) = try await perform { store -> (Bool, Bool) in
                let settings = try store.privacySettings()
                guard try !store.isPaused(), !ClipboardPasteboard.ignores(front), !settings.excludes(front) else {
                    try store.discardObservation(generation)
                    return (false, false)
                }
                let board = name == NSPasteboard.Name.general.rawValue ? NSPasteboard.general : NSPasteboard(name: .init(name))
                guard board.changeCount == count else { return (false, false) }
                // Some writers clear, render, then set data without incrementing changeCount again.
                guard board.types?.isEmpty == false else { return (false, true) }
                guard let capture = ClipboardPasteboard.capture(board, expectedChange: count, frontmostBundleID: front,
                                                                frontmostName: frontName, privacy: settings) else {
                    if board.changeCount == count, let items = board.pasteboardItems, items.count <= 200,
                       ClipboardPasteboard.taggedSources(in: items).contains(where: settings.excludes) {
                        try store.discardObservation(generation)
                    }
                    return (false, false)
                }
                return (try store.record(capture, observing: generation, at: now), false)
            }
            if !empty, lastChange == count { emptyRetries = 0 }
            if changed { await didChange() }
        } catch { issue = "Couldn’t save the copied item to clipboard history." }
    }

    private func didChange() async {
        DistributedNotificationCenter.default().postNotificationName(Self.changes, object: instance, userInfo: nil, deliverImmediately: true)
        await synchronize()
    }

    func entries(matching query: String) async -> [ClipboardEntry] {
        do { return try await perform { try $0.entries(matching: query) } }
        catch { issue = "Couldn’t search clipboard history."; return [] }
    }

    func content(for entry: ClipboardEntry) async -> ClipboardContent? {
        do { return try await perform { try $0.content(for: entry.id) } }
        catch { issue = "Couldn’t read this clipboard entry."; return nil }
    }

    func setPaused(_ value: Bool) {
        paused = value
        lastChange = pasteboard.changeCount
        emptyRetries = 0
        modify { try $0.setPaused(value) }
    }

    func remove(_ entry: ClipboardEntry) { modify { try $0.remove(entry.id) } }

    func clear() { modify { try $0.clear() } }

    func setRetention(_ period: ClipboardRetention) { modify { try $0.setRetention(period) } }
    func excludeApplications(_ apps: [ClipboardExcludedApp]) { modify { try $0.exclude(apps) } }
    func removeExclusion(_ id: String) { modify { try $0.removeExclusion(id) } }

    func showPrivacySettings() {
        window.showPrivacySettings()
        Task { await synchronize() }
    }

    private func modify(_ update: @escaping @Sendable (ClipboardStore) throws -> Void) {
        Task {
            do {
                try await perform(update)
                await didChange()
            } catch {
                await synchronize()
                issue = "Couldn’t update clipboard history. Please try again."
            }
        }
    }

    func commands() -> [ToolCommand] {
        [ToolCommand(id: "clipboard.history", title: "Clipboard History", subtitle: "Inspect and reuse copied text, images, files, links and colors",
                     symbol: "list.clipboard", group: "Clipboard", keywords: "pasteboard recent copies screenshots photos text snippets pin edit paste as color email links information actions") {
            self.showHistory()
        }, ToolCommand(id: "clipboard.privacy", title: "Clipboard History Settings",
                       subtitle: "Choose when copies expire and which apps to exclude", symbol: "lock",
                       group: "Clipboard", keywords: "privacy retention duration days ignored excluded applications") {
            self.showPrivacySettings()
        }]
    }

    func showHistory() {
        pasteTarget = TargetApplication.current
        window.toggle()
        Task { await synchronize() }
    }

    func snippets(matching query: String) async -> [ClipboardEntry] {
        do { return try await perform { try $0.snippets(matching: query) } }
        catch { issue = "Couldn’t search saved snippets."; return [] }
    }

    func capture(for entry: ClipboardEntry) async -> ClipboardCapture? {
        do { return try await perform { try $0.capture(for: entry.id) } }
        catch { issue = "Couldn’t read the saved formats."; return nil }
    }

    func members(for entry: ClipboardEntry) async -> [ClipboardContent]? {
        do {
            return try await perform { store in
                try store.withPreviewCopies(for: entry.id) { try ClipboardFileActions.contents(of: $0, root: $1) }
            }
        } catch { Feedback.show("Couldn’t read all the items in this clipboard entry."); return nil }
    }

    func setPinned(_ value: Bool, for entry: ClipboardEntry) { modify { try $0.setPinned(entry.id, value) } }
    func rename(_ entry: ClipboardEntry, to title: String) { modify { try $0.rename(entry.id, to: title) } }
    func edit(_ entry: ClipboardEntry, text: String) { modify { _ = try $0.edit(entry.id, text: text) } }
    func saveSnippet(_ entry: ClipboardEntry, named name: String) { modify { _ = try $0.saveSnippet(entry.id, named: name) } }
    func clear(since date: Date) { modify { try $0.clear(since: date) } }

    func copy(_ entry: ClipboardEntry, as type: String? = nil) { restore(entry, as: type, paste: false, keepOpen: false) }
    func paste(_ entry: ClipboardEntry, as type: String? = nil, keepOpen: Bool = false) {
        restore(entry, as: type, paste: true, keepOpen: keepOpen)
    }

    func prepareChatDraft(_ entry: ClipboardEntry) async -> Bool {
        guard let capture = await capture(for: entry), ClipboardPasteboard.write(capture, to: pasteboard) else {
            Feedback.show("Couldn’t prepare this clipboard entry."); return false
        }
        lastChange = pasteboard.changeCount
        window.hide()
        return true
    }

    func copyText(_ text: String) {
        guard ClipboardPasteboard.write(.text(text), to: pasteboard) else { issue = "Couldn’t write the text to the clipboard."; return }
        lastChange = pasteboard.changeCount
        window.hide()
        Feedback.show("Copied to clipboard")
    }

    func pasteText(_ text: String) {
        guard ClipboardPasteboard.write(.text(text), to: pasteboard) else { issue = "Couldn’t write the text to the clipboard."; return }
        lastChange = pasteboard.changeCount
        let target = pasteTarget
        let change = lastChange
        window.hide()
        Task { await pasteIntoTarget(target, change: change) }
    }

    private func restore(_ entry: ClipboardEntry, as type: String?, paste: Bool, keepOpen: Bool) {
        let target = pasteTarget
        Task {
            guard let capture = await capture(for: entry) else {
                await synchronize()
                issue = "That entry is no longer available."
                return
            }
            guard ClipboardPasteboard.write(capture, as: type, to: pasteboard) else {
                issue = "Couldn’t restore the selected format."; return
            }
            lastChange = pasteboard.changeCount
            let savedChange = lastChange
            if keepOpen { window.suspendForPaste() } else { window.hide() }
            guard paste else { Feedback.show("Copied to clipboard"); return }
            await pasteIntoTarget(target, change: savedChange)
            if keepOpen {
                // Let the receiver process its paste before reclaiming key-window status.
                try? await Task.sleep(nanoseconds: 60_000_000)
                window.resumeAfterPaste()
            }
        }
    }

    private func pasteIntoTarget(_ target: NSRunningApplication?, change: Int) async {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            Feedback.show("Copied. Press ⌘V to paste. Direct paste requires Accessibility access.")
            return
        }
        guard let target, !target.isTerminated else {
            Feedback.show("Copied. Press ⌘V in the app where you want to paste.")
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier {
            target.activate(options: [.activateIgnoringOtherApps])
        }
        for _ in 0..<20 {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontPID == target.processIdentifier { break }
            if let frontPID, frontPID != NSRunningApplication.current.processIdentifier { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard pasteboard.changeCount == change else {
            Feedback.show("The clipboard changed. Select the entry again to paste it."); return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              Self.postPaste(to: target.processIdentifier) else {
            Feedback.show("Copied. Press ⌘V in the app where you want to paste."); return
        }
    }

    private func indexImagesIfNeeded() {
        guard imageIndexing == nil, !paused else { return }
        attemptedOCR.formIntersection(entries.map(\.id))
        let pending = entries.filter { entry in
            let images = entry.kind == .image || (entry.itemCount > 1 && entry.formatTypes.contains {
                UTType($0)?.conforms(to: .image) == true
            })
            return images && entry.recognizedText == nil && !attemptedOCR.contains(entry.id)
        }.map(\.id)
        guard !pending.isEmpty else { return }
        attemptedOCR.formUnion(pending)
        let store = self.store
        imageIndexing = Task { [weak self] in
            for id in pending {
                guard !Task.isCancelled, self != nil else { return }
                let saved = await Task.detached(priority: .utility) {
                    autoreleasepool {
                        do {
                            guard let capture = try store.capture(for: id) else { return false }
                            let text = try Self.recognition(in: capture, qr: false)
                            try store.setRecognizedText(text, for: id)
                            return true
                        } catch { return false }
                    }
                }.value
                if saved { await self?.didChange() }
            }
            self?.imageIndexing = nil
            self?.indexImagesIfNeeded()
        }
    }

    nonisolated private static func recognition(in capture: ClipboardCapture, qr: Bool) throws -> String {
        let results = try ClipboardPasteboard.members(of: capture).compactMap { member -> String? in
            guard case .content(.image(let data)) = member else { return nil }
            let text = try qr ? ClipboardImageRecognition.qrCodes(in: data) : ClipboardImageRecognition.text(in: data)
            return text.isEmpty ? nil : text
        }
        return results.joined(separator: "\n")
    }

    func copyRecognizedText(_ entry: ClipboardEntry) { copyImageText(entry, qr: false) }
    func copyQRCode(_ entry: ClipboardEntry) { copyImageText(entry, qr: true) }

    private func copyImageText(_ entry: ClipboardEntry, qr: Bool) {
        Task {
            do {
                let text: String
                if !qr, let cached = entry.recognizedText { text = cached }
                else {
                    guard let capture = await capture(for: entry) else { return }
                    text = try await Task.detached(priority: .userInitiated) { try Self.recognition(in: capture, qr: qr) }.value
                    if !qr { try await perform { try $0.setRecognizedText(text, for: entry.id) }; await didChange() }
                }
                guard !text.isEmpty else { Feedback.show(qr ? "No QR code found in this image." : "No text found in this image."); return }
                copyText(text)
            } catch { Feedback.show("Couldn’t read this image. Try again.") }
        }
    }

    func open(_ entry: ClipboardEntry) { fileAction(.open, entry) }
    func reveal(_ entry: ClipboardEntry) { fileAction(.reveal, entry) }
    func openWith(_ entry: ClipboardEntry) { fileAction(.openWith, entry) }
    func annotate(_ entry: ClipboardEntry) { fileAction(.annotate, entry) }
    func quickLook(_ entry: ClipboardEntry) { fileAction(.quickLook, entry) }
    func saveAsFile(_ entry: ClipboardEntry) { fileAction(.save, entry) }

    private func fileAction(_ action: ClipboardFileActions.Action, _ entry: ClipboardEntry) {
        Task {
            if action != .quickLook { window.hide() }
            await fileActions.run(action, on: entry, store: store)
        }
    }

    func share(_ entry: ClipboardEntry, from anchor: NSView) {
        Task {
            guard anchor.window != nil else { return }
            await fileActions.share(entry, store: store, from: anchor)
        }
    }

    func copyFilePaths(_ entry: ClipboardEntry) {
        Task {
            guard let capture = await capture(for: entry) else { return }
            let urls = await Task.detached(priority: .userInitiated) {
                ClipboardPasteboard.members(of: capture).flatMap { member -> [URL] in
                    if case .content(.files(let files)) = member { return files }
                    return []
                }
            }.value
            guard !urls.isEmpty else { Feedback.show("This entry contains no file paths."); return }
            copyText(urls.map(\.path).joined(separator: "\n"))
        }
    }

    private static func postPaste(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        // Command shortcuts follow the active keyboard layout. Try the ANSI V key first.
        let keys: [CGKeyCode] = [9] + (0..<128).filter { $0 != 9 }
        let down = keys.lazy.compactMap { code -> CGEvent? in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return nil }
            event.flags = .maskCommand
            return NSEvent(cgEvent: event)?.characters(byApplyingModifiers: .command)?.lowercased() == "v" ? event : nil
        }.first
        guard let down, let up = down.copy() else { return false }
        up.type = .keyUp
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
