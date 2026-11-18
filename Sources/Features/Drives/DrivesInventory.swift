import CryptoKit
import DiskArbitration
import Foundation
import IOKit

struct ExternalDrive: Equatable, Sendable {
    let bsd: String
    let name: String
    let detail: String
    let identity: String
    let attachment: UInt64
    let persistent: Bool

    var commandID: String { "drives.eject." + identity }
}

struct DriveError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DriveInventory {
    typealias Plist = [String: Any]
    static let session = UUID().uuidString

    static func wholeDisk(_ identifier: String) -> String? {
        guard identifier.range(of: #"^disk[0-9]+(s[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        return String(identifier.prefix(4) + identifier.dropFirst(4).prefix(while: \.isNumber))
    }

    static func bootDisks(_ info: Plist) throws -> Set<String> {
        if let stores = info["APFSPhysicalStores"] as? [Plist], !stores.isEmpty {
            let disks = stores.compactMap { ($0["APFSPhysicalStore"] as? String).flatMap(wholeDisk) }
            guard disks.count == stores.count else { throw DriveError(message: "Couldn’t identify every startup disk.") }
            return Set(disks)
        }
        guard info["VirtualOrPhysical"] as? String == "Physical",
              let id = info["DeviceIdentifier"] as? String, let disk = wholeDisk(id) else {
            throw DriveError(message: "Couldn’t identify the physical startup disk.")
        }
        return [disk]
    }

    static func eligible(_ info: Plist, id: String, protected: Set<String>) -> Bool {
        wholeDisk(id) == id && !protected.contains(id) && info["DeviceIdentifier"] as? String == id &&
            info["WholeDisk"] as? Bool == true && info["Internal"] as? Bool == false &&
            info["VirtualOrPhysical"] as? String == "Physical"
    }

    // The registry ID identifies this particular attachment even when macOS reuses a BSD disk number.
    static func attachmentID(_ id: String) -> UInt64? {
        guard let session = DASessionCreate(nil),
              let disk = DADiskCreateFromBSDName(nil, session, id) else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS else { return nil }
        return entryID
    }

    static func diskutil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DriveError(message: message.isEmpty ? "diskutil exited with status \(process.terminationStatus)." : String(message.prefix(900)))
        }
        return bytes
    }

    private static func read(_ arguments: [String]) throws -> Plist {
        let bytes = try diskutil(arguments)
        guard let result = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? Plist else {
            throw DriveError(message: "Couldn’t read the disk inventory.")
        }
        return result
    }

    static func makeDrive(row: Plist, info: Plist, containers: [Plist], bsd: String, attachment: UInt64) -> ExternalDrive {
        let children = row["Partitions"] as? [Plist] ?? []
        let volumes = ([row] + children + containers.flatMap { $0["APFSVolumes"] as? [Plist] ?? [] })
        // Mounted names match Finder, including volumes on synthesized APFS containers.
        let mounted = volumes.filter { ($0["MountPoint"] as? String)?.isEmpty == false }
        let names = mounted.compactMap { $0["VolumeName"] as? String }.filter { !$0.isEmpty && $0 != "EFI" }
        let mediaName = (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "External drive"
        let name = names.first ?? mediaName
        let count = names.count > 1 ? "\(names.count) volumes" : nil
        let size = (info["TotalSize"] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .decimal) }
        let detail = [count, size, info["BusProtocol"] as? String, bsd].compactMap { $0 }.joined(separator: " · ")
        let diskUUID = (row["DiskUUID"] as? String) ?? (info["DiskUUID"] as? String)
        let partitionUUIDs = children.compactMap { $0["DiskUUID"] as? String }.sorted()
        let volumeUUIDs = volumes.compactMap { $0["VolumeUUID"] as? String }.sorted()
        let ids = [diskUUID].compactMap { $0 } + partitionUUIDs + volumeUUIDs
        // Prefer a partition over a volume ID so renaming or unmounting APFS volumes keeps a shortcut.
        let stable = ids.first { UUID(uuidString: $0) != nil }
        let rawID = stable?.lowercased() ?? "\(session)-\(attachment)"
        let digest = SHA256.hash(data: Data(rawID.utf8)).map { String(format: "%02x", $0) }.joined()
        return ExternalDrive(bsd: bsd, name: name, detail: detail, identity: digest, attachment: attachment, persistent: stable != nil)
    }

    static func list() throws -> [ExternalDrive] {
        let inventory = try read(["list", "-plist", "external", "physical"])
        guard let rows = inventory["AllDisksAndPartitions"] as? [Plist] else {
            throw DriveError(message: "Couldn’t read external disks.")
        }
        if rows.isEmpty { return [] }
        let protected = try bootDisks(read(["info", "-plist", "/"]))
        guard let all = try read(["list", "-plist"])["AllDisksAndPartitions"] as? [Plist] else {
            throw DriveError(message: "Couldn’t resolve the storage layout.")
        }
        var drives: [ExternalDrive] = []
        for row in rows {
            guard let bsd = row["DeviceIdentifier"] as? String, wholeDisk(bsd) == bsd,
                  !protected.contains(bsd), let attachment = attachmentID(bsd) else { continue }
            let info = try read(["info", "-plist", bsd])
            guard eligible(info, id: bsd, protected: protected), attachmentID(bsd) == attachment else { continue }
            let containers = all.filter { container in
                (container["APFSPhysicalStores"] as? [Plist] ?? []).contains {
                    ($0["DeviceIdentifier"] as? String).flatMap(wholeDisk) == bsd
                }
            }
            // A multi-store container cannot be independently removed one member at a time.
            let spansDisks = containers.contains { container in
                (container["APFSPhysicalStores"] as? [Plist] ?? []).contains {
                    ($0["DeviceIdentifier"] as? String).flatMap(wholeDisk) != bsd
                }
            }
            let children = row["Partitions"] as? [Plist] ?? []
            let managedStorage = ([row] + children).contains {
                let content = ($0["Content"] as? String ?? "").lowercased()
                return content.contains("raid") || content.contains("corestorage")
            }
            if spansDisks || managedStorage { continue }
            drives.append(makeDrive(row: row, info: info, containers: containers, bsd: bsd, attachment: attachment))
        }
        return distinguish(drives)
    }

    static func distinguish(_ drives: [ExternalDrive]) -> [ExternalDrive] {
        let duplicates = Dictionary(grouping: drives, by: \.identity).filter { $0.value.count > 1 }
        return drives.map { drive in
            guard duplicates[drive.identity] != nil else { return drive }
            return ExternalDrive(bsd: drive.bsd, name: drive.name, detail: drive.detail,
                                 identity: "\(drive.identity)-\(session)-\(drive.attachment)",
                                 attachment: drive.attachment, persistent: false)
        }.sorted { ($0.name, $0.bsd) < ($1.name, $1.bsd) }
    }

    static func checkedTarget(_ expected: ExternalDrive, in candidates: [ExternalDrive], attachment: (String) -> UInt64?) throws -> ExternalDrive {
        guard let live = candidates.first(where: { $0.bsd == expected.bsd && $0.identity == expected.identity
            && $0.attachment == expected.attachment }), attachment(live.bsd) == expected.attachment else {
            throw DriveError(message: "This drive disconnected or changed. Refresh and try again.")
        }
        return live
    }

    static func eject(_ drive: ExternalDrive, from snapshot: [ExternalDrive]) throws {
        let live = try checkedTarget(drive, in: snapshot, attachment: attachmentID)
        // diskutil coordinates APFS and ordinary partitions and returns nonzero for busy media.
        _ = try diskutil(["eject", "/dev/" + live.bsd])
    }
}

struct EjectReport {
    let summary: String
    let detail: String

    static func run(selected: ExternalDrive?, inventory: () throws -> [ExternalDrive],
                    eject: (ExternalDrive, [ExternalDrive]) throws -> Void) -> Self {
        do {
            // Capture a fresh inventory once, then validate each attachment immediately before ejection.
            let snapshot = try inventory()
            let list = selected.map { [$0] } ?? snapshot
            if list.isEmpty {
                return Self(summary: "No eligible external drives connected", detail: "No eligible external drives were found.")
            }
            var failures: [String] = []
            var successes: [String] = []
            for drive in list {
                do {
                    try eject(drive, snapshot)
                    successes.append(drive.name)
                } catch {
                    failures.append("\(drive.name) (\(drive.bsd)) · \(error.localizedDescription)")
                }
            }
            var detail = successes.map { "Ejected \($0)" }
            detail += failures.map { "Couldn’t eject \($0)" }
            let summary: String
            if failures.isEmpty {
                let subject = successes.count == 1 ? successes[0] : "\(successes.count) drives"
                summary = "Ejected \(subject) · Safe to disconnect"
            } else {
                let subject = list.count == 1 ? list[0].name : "\(failures.count) of \(list.count) drives"
                summary = "Couldn’t eject \(subject) · See Last Eject Result"
            }
            return Self(summary: summary, detail: detail.joined(separator: "\n"))
        } catch {
            return Self(summary: "Couldn’t check external drives · See Last Eject Result", detail: error.localizedDescription)
        }
    }
}
