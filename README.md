# Shad Tools

A keyboard-first toolbox for macOS. Open one palette to find a file, keep your microphone selected, eject your drives, sample a color, or arrange two windows side by side. Shad Tools runs locally and requires no account.

## Install

Download the **Shad Tools** package for the complete palette, or pick one of the five standalone installers. Each installer contains a self-contained application for Apple silicon and Intel Macs targeting macOS 13 or later. Open the installed app from Applications. [Download version 0.1.0](https://github.com/SyedShad/shad-tools/releases/tag/v0.1.0)

| Installer | What it does | Open the palette |
| --- | --- | --- |
| **Shad Tools** | All five tools in one menu bar app | ⌃⌥Space |
| **Shad Search** | Search apps, commands, filenames, and paths | ⌃⌥⌘S |
| **Shad Audio** | Pin system input and output independently | ⌃⌥⌘A |
| **Shad Eject** | Safely eject one physical drive or all eligible drives | ⌃⌥⌘D |
| **Shad Color** | Sample a pixel and copy HEX, RGB, or HSL | ⌃⌥⌘C |
| **Shad Windows** | Tile windows, snap adjacent edges, and resize linked windows | ⌃⌥⌘W |

Version 0.1.0 is a public preview. The apps use ad hoc code signatures. The installer packages are unsigned and have no Apple notarization ticket. Gatekeeper may block an internet download. A local source build is available below. Apple describes its installer verification and approval controls in its [Mac software distribution guide](https://developer.apple.com/macos/distribution/).

## First use

- Press **Control + Option + Space** or click the suite’s menu bar icon. Type to search across tools, or open a category to browse its commands. Use **↑**, **↓**, and **Return**. **Escape** clears the query, goes back, or closes the palette.
- For Bluetooth headphones, open **Audio Manager** and choose **Pin Input to** your usual microphone. Leave output routing automatic if you want to hear your headphones when they connect. [Audio and drive guide](docs/hardware.md)
- Press **Control + Option + Command + E** to eject eligible external drives. Wait for the result before unplugging. For one specific drive, select its command and press **⌘K** to record a shortcut. [Drive behavior and busy disks](docs/hardware.md#leave-with-your-drives)
- Focus a window and press **Control + Option + Command + an arrow** to tile it to that half of the display. Grant Accessibility access when macOS requests it. Drag one window beside another until the snap preview appears, then drop and resize their shared edge. [Window layouts and magnetic resizing](docs/windows.md)
- Select **Pick Screen Color as HEX**, move the magnifier over a pixel, and click. The result is ready to paste. [Search and color guide](docs/search-color.md)
- Use **⌘,** or the sliders button for shortcut settings and **Start at login**. A warning beside a binding means another app or macOS already uses it. Control-click the menu bar icon to quit. Running both the suite and a standalone copy of the same tool can create competing bindings. Choose the edition you want to keep running.

## Build and test

On macOS with recent Xcode or Command Line Tools and Swift 6 or newer:

```sh
git clone https://github.com/SyedShad/shad-tools.git
cd shad-tools
./scripts/test.sh
./scripts/package.sh
./scripts/verify-packages.sh
open "dist/apps/Shad Tools.app"
```

The release script creates six universal installers, app bundles, and a SHA-256 manifest in `dist/`. Each edition has its own bundle ID and initializes only its own tools. Shad Audio and the suite share route pins. The app has no third-party package dependencies.

To check downloaded packages, place all six and the manifest in one directory and run `shasum -a 256 -c SHA256SUMS-0.1.0.txt` there. Maintainers can set `APP_SIGN_IDENTITY`, `INSTALLER_SIGN_IDENTITY`, and `NOTARY_PROFILE` when running the release script with their own Developer ID certificates and notarytool keychain profile.

## Project

The keyboard interaction takes inspiration from Raycast's search and hotkey walkthroughs, and the tiling commands follow familiar Rectangle layouts. The feature guides link the native APIs and design references. [Raycast quickstart and video](https://manual.raycast.com/quickstart) · [Rectangle](https://github.com/rxhanson/Rectangle)

Shad Tools is available under the [MIT license](LICENSE). This release is for macOS.
