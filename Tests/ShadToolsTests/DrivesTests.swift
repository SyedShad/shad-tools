import Testing
@testable import ShadTools

struct DrivesTests {
    let external: DriveInventory.Plist = [
        "DeviceIdentifier": "disk12", "WholeDisk": true, "Internal": false, "VirtualOrPhysical": "Physical"
    ]
    let one = ExternalDrive(bsd: "disk12", name: "Photos", detail: "", identity: "drive-a", attachment: 1234, persistent: true)
    let two = ExternalDrive(bsd: "disk9", name: "Archive", detail: "", identity: "drive-b", attachment: 4321, persistent: true)

    @Test func protectsAllAPFSStartupStoresIncludingExternalBoot() throws {
        let protected = try DriveInventory.bootDisks(["APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk12s1"], ["APFSPhysicalStore": "disk0s3"]
        ]])
        #expect(protected == ["disk12", "disk0"])
        #expect(!DriveInventory.eligible(external, id: "disk12", protected: protected))
        #expect(throws: DriveError.self) { try DriveInventory.bootDisks(["VirtualOrPhysical": "Virtual", "ParentWholeDisk": "disk1"]) }
        #expect(throws: DriveError.self) { try DriveInventory.bootDisks(["APFSPhysicalStores": [["APFSPhysicalStore": "??"]]]) }
    }

    @Test func acceptsOnlyWholeExternalPhysicalDevices() {
        #expect(DriveInventory.eligible(external, id: "disk12", protected: ["disk0"]))
        for (key, value) in [("Internal", true as Any), ("WholeDisk", false as Any), ("VirtualOrPhysical", "Virtual" as Any)] {
            var unsafe = external
            unsafe[key] = value
            #expect(!DriveInventory.eligible(unsafe, id: "disk12", protected: []))
            unsafe.removeValue(forKey: key)
            #expect(!DriveInventory.eligible(unsafe, id: "disk12", protected: []))
        }
        #expect(!DriveInventory.eligible(external, id: "disk12s1", protected: []))
        #expect(DriveInventory.wholeDisk("disk12s1s2") == "disk12")
        #expect(DriveInventory.wholeDisk("disk12invalid") == nil)
    }

    @Test func shortcutUsesStableMediaIDAndAPFSVolumeName() {
        let row: DriveInventory.Plist = ["Partitions": [["DiskUUID": "abcdef12-0000-4000-8000-000000000001"]]]
        let containers: [DriveInventory.Plist] = [["APFSVolumes": [["VolumeName": "Weekend", "MountPoint": "/Volumes/Weekend"]]]]
        let a = DriveInventory.makeDrive(row: row, info: [:], containers: containers, bsd: "disk2", attachment: 9)
        let b = DriveInventory.makeDrive(row: row, info: [:], containers: [], bsd: "disk19", attachment: 52)
        #expect(a.name == "Weekend")
        #expect(a.persistent)
        #expect(a.commandID == b.commandID)
        let bare = DriveInventory.makeDrive(row: [:], info: [:], containers: [], bsd: "disk19", attachment: 52)
        #expect(!bare.persistent)
    }

    @Test func clonedMediaGetsSeparateTemporaryIDs() {
        let clone = ExternalDrive(bsd: two.bsd, name: one.name, detail: "", identity: one.identity,
                                  attachment: two.attachment, persistent: true)
        let resolved = DriveInventory.distinguish([one, clone])
        #expect(Set(resolved.map(\.commandID)).count == 2)
        #expect(resolved.allSatisfy { !$0.persistent && $0.commandID != one.commandID })
    }

    @Test func staleAttachmentNeverResolvesReusedDeviceNumber() throws {
        #expect(try DriveInventory.checkedTarget(one, in: [one, two], attachment: { _ in one.attachment }) == one)
        #expect(throws: DriveError.self) { try DriveInventory.checkedTarget(one, in: [one], attachment: { _ in two.attachment }) }
        #expect(throws: DriveError.self) { try DriveInventory.checkedTarget(one, in: [], attachment: { _ in nil }) }
    }

    @Test func busyDriveDoesNotBlockRemainingEjections() {
        var attempted: [String] = []
        let report = EjectReport.run(selected: nil, inventory: { [one, two] }) { drive, _ in
            attempted.append(drive.bsd)
            if drive == one { throw DriveError(message: "volume is in use") }
        }
        #expect(attempted == [one.bsd, two.bsd])
        #expect(report.summary.contains("1 of 2"))
        #expect(report.detail.contains("volume is in use"))
        #expect(report.detail.contains("Ejected Archive"))
        #expect(!report.summary.contains("Safe to disconnect"))
    }
}
