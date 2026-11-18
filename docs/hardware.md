# Audio and external drives

## Rank your microphones and speakers

Open **Audio Manager → Manage Input Priorities** or **Manage Output Priorities**. Each list is independent. Use the arrow buttons to move a device up or down, or use **Make First** to put it at the top. The first connected device that supports that direction becomes the system default. Devices keep their positions while disconnected. A newly discovered device joins the bottom of its list.

For example, put your MacBook microphone above your headset under **Input**, then put the headset above your MacBook speakers under **Output**. Connecting the headset sends playback to it while the MacBook microphone keeps handling input. If the headset disconnects, the next available output takes over. Reconnecting restores the higher-ranked output.

On first launch each list starts with the current system default. An existing Shad Audio pin becomes the first-ranked device when upgrading. The suite and standalone audio app share rankings. Turn off **Use input priorities** or **Use output priorities** to give macOS control of that direction while keeping the saved order. You can also reorder disconnected devices or forget one from its context menu.

Keep Shad Tools or Shad Audio running for automatic switching. Core Audio reports connections and default changes, and Shad reapplies the winning route when macOS or another app changes it. The hardware can switch briefly during a connection. An app with an explicitly selected device follows its own setting. Choose the system default in that app to follow your ranking.

## Leave with your drives

Open **Easy Eject**. Each connected physical drive has an **Eject** command, with its size, transport and current disk identifier shown when available. A multi-volume drive has one eject action for the whole device. Assign a shortcut to that command using the palette’s shortcut settings. **Eject All External Drives** defaults to Control + Option + Command + E.

Wait for **Safe to disconnect** before unplugging. If a drive is busy, the app continues with the others. Open **Show Last Eject Result** for each outcome and the error macOS reported. Close the document or app holding the drive and retry. [Apple’s guide to busy disks](https://support.apple.com/guide/mac-help/eject-a-disk-mac-app-mh27076/mac)

The app uses macOS Disk Arbitration to detect hardware changes and the system’s standard `diskutil eject` operation to unmount and eject. It checks the physical startup stores, the current inventory and the I/O Registry attachment identifier. The eligible set consists of directly attached external physical media. Disk images, network shares, internal drives, startup disks, software RAID, CoreStorage groups and APFS containers spanning multiple physical drives fall outside that set.

Individual bindings normally follow a disk or partition UUID across reconnection and disk-number changes. Reformatting or repartitioning a drive can change its identity. If a disk has no usable UUID, or two connected drives have matching identities, its displayed shortcut applies only to that connection. A disk-image clone mounted on a physical device can have the same identifiers as its original.

## Implementation references

Core Audio identifies default input and output devices independently and publishes changes through property listeners. [Apple’s Core Audio listener documentation](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)) and [SwitchAudioSource’s device-selection examples](https://github.com/deweller/switchaudio-osx#usage).

Apple documents the relationship between whole disks, their volumes and ejection in the Disk Arbitration Programming Guide. The installed `man diskutil` manual describes the eject operation used by Shad Eject. [Apple’s disk manipulation guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html).
