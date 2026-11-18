import ShadCore
import AppKit
import DiskArbitration

private extension Notification.Name {
    static let driveTopologyChanged = Notification.Name("ShadTools.driveTopologyChanged")
}

private func drivesChanged(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    NotificationCenter.default.post(name: .driveTopologyChanged, object: nil)
}

@MainActor
final class DrivesTool {
    private let session = DASessionCreate(nil)
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshTask: Task<Void, Never>?
    private var drives: [ExternalDrive] = []
    private var scanning = true
    private var working = false
    private var scanError: String?
    private var report = ""

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [(NotificationCenter.default, Notification.Name.driveTopologyChanged),
                               (workspace, NSWorkspace.didMountNotification),
                               (workspace, NSWorkspace.didUnmountNotification),
                               (workspace, NSWorkspace.didRenameVolumeNotification),
                               (workspace, NSWorkspace.didWakeNotification)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            observers.append((center, token))
        }
        if let session {
            DARegisterDiskAppearedCallback(session, nil, drivesChanged, nil)
            DARegisterDiskDisappearedCallback(session, nil, drivesChanged, nil)
            DASessionSetDispatchQueue(session, .main)
        }
        refresh()
    }

    deinit {
        refreshTask?.cancel()
        if let session { DASessionSetDispatchQueue(session, nil) }
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .utility) { Result { try DriveInventory.list() } }.value
            guard !Task.isCancelled, let self else { return }
            self.scanning = false
            switch result {
            case .success(let list):
                self.drives = list
                self.scanError = nil
            case .failure(let error):
                self.drives = []
                self.scanError = error.localizedDescription
            }
            Commands.changed()
        }
    }

    private func eject(_ selected: ExternalDrive?) {
        guard !working else {
            Feedback.show("An eject is already in progress")
            return
        }
        working = true
        Feedback.show(selected.map { "Ejecting \($0.name)…" } ?? "Checking external drives…")
        Commands.changed()
        Task {
            let messages = await Task.detached(priority: .userInitiated) {
                EjectReport.run(selected: selected, inventory: DriveInventory.list, eject: DriveInventory.eject)
            }.value
            working = false
            report = messages.detail
            Feedback.show(messages.summary)
            Commands.changed()
            refresh()
        }
    }

    func commands() -> [ToolCommand] {
        let count = drives.count
        let status: String
        if working { status = "Ejection in progress" }
        else if let scanError { status = scanError }
        else if scanning { status = "Checking connected drives" }
        else if count == 0 { status = "No eligible drives connected" }
        else { status = "\(count) external \(count == 1 ? "drive" : "drives") connected" }
        var result = [
            ToolCommand(id: "drives.eject-all", title: "Eject All External Drives", subtitle: status,
                        symbol: "eject.fill", group: "Drives", keywords: "disconnect disks storage usb ssd safely eject hard drive all") { [weak self] in
                self?.eject(nil)
            }
        ]
        for drive in drives {
            let detail = drive.persistent ? drive.detail : drive.detail + " · Shortcut lasts for this connection"
            result.append(ToolCommand(id: drive.commandID, title: "Eject \(drive.name)", subtitle: detail,
                                      symbol: "externaldrive", group: "Drives", keywords: "disconnect disk usb ssd safely eject hard drive") { [weak self] in
                self?.eject(drive)
            })
        }
        if scanError != nil {
            result.append(ToolCommand(id: "drives.refresh", title: "Refresh External Drives", subtitle: "Check the current disk inventory",
                                      symbol: "arrow.clockwise", group: "Drives") { [weak self] in self?.refresh() })
        }
        if !report.isEmpty {
            result.append(ToolCommand(id: "drives.last-result", title: "Show Last Eject Result", subtitle: "See the outcome for each requested drive",
                                      symbol: "list.bullet.rectangle", group: "Drives") { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Last eject result"
                alert.informativeText = self.report
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            })
        }
        return result
    }
}
