# Audio and external drives

## Keep a microphone selected

Open **Audio Manager** and choose **Pin Input to** your preferred microphone. Leave the output unpinned if you want the Mac to route playback to newly connected headphones. To keep playback on a particular device too, choose **Pin Output to** that device.

The app listens for Core Audio device and default-route changes while it runs. When macOS changes a pinned route, the app restores it. macOS can briefly select a different device while a headset connects. Apps with their own microphone or speaker selection may continue to use that specific device. Choose the system default in those apps if you want them to follow the pin.

A disconnected pin stays saved. macOS can use an available device until the preferred device returns. **Unpin Audio Input** and **Unpin Audio Output** restore automatic selection for their respective routes. The suite and standalone audio app share these preferences. Device identifiers and names stay on your Mac.

## Leave with your drives

Open **Easy Eject**. Each connected physical drive has an **Eject** command, with its size, transport and current disk identifier shown when available. A multi-volume drive has one eject action for the whole device. Assign a shortcut to that command using the palette’s shortcut settings. **Eject All External Drives** defaults to Control + Option + Command + E.

Wait for **Safe to disconnect** before unplugging. If a drive is busy, the app continues with the others. Open **Show Last Eject Result** for each outcome and the error macOS reported. Close the document or app holding the drive and retry. [Apple’s guide to busy disks](https://support.apple.com/guide/mac-help/eject-a-disk-mac-app-mh27076/mac)

The app uses macOS Disk Arbitration to detect hardware changes and the system’s standard `diskutil eject` operation to unmount and eject. It checks the physical startup stores, the current inventory and the I/O Registry attachment identifier. The eligible set consists of directly attached external physical media. Disk images, network shares, internal drives, startup disks, software RAID, CoreStorage groups and APFS containers spanning multiple physical drives fall outside that set.

Individual bindings normally follow a disk or partition UUID across reconnection and disk-number changes. Reformatting or repartitioning a drive can change its identity. If a disk has no usable UUID, or two connected drives have matching identities, its displayed shortcut applies only to that connection. A disk-image clone mounted on a physical device can have the same identifiers as its original.

## Implementation references

Core Audio identifies default input and output devices independently and publishes changes through property listeners. [Apple’s Core Audio listener documentation](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)) and [SwitchAudioSource’s device-selection examples](https://github.com/deweller/switchaudio-osx#usage).

Apple documents the relationship between whole disks, their volumes and ejection in the Disk Arbitration Programming Guide. The installed `man diskutil` manual describes the eject operation used by Shad Eject. [Apple’s disk manipulation guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html).
