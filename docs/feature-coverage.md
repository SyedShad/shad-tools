# Feature coverage on macOS

**Audit date: 19 November 2026.** This comparison covers the eight Shad tools and the behaviors their reference apps provide. The installed references on the audit Mac were Raycast 2.13.1.0, Rectangle 2.0.4 and MacShot 4.4.0. The Raycast manual is updated independently of the installed app. The supplied clipboard recording provided a second reference for the selected-item interface.

**Present** means the action has a user-facing entry point and an implementation. **Partial** identifies a difference that matters when following the same workflow. **Missing** means the reviewed Shad edition has no equivalent. **Needs a device test** identifies a verification limit. The comparisons for Audio, Eject and Color use the original request as their baseline because it named no competing app.

## Search and the shared palette

| Workflow | Coverage |
| --- | --- |
| Open the launcher, find commands or apps by name or initials, act from the keyboard | **Present.** Global shortcut, grouped results, tool navigation, Return, a searchable ⌘K action panel, configurable command shortcuts, favorites and recent command suggestions. The palette supports system, light and dark appearances. |
| Find files and folders without opening Finder | **Partial.** Search matches names indexed by Spotlight under the home folder or an explicitly entered path. Shad opens and reveals results, previews files with Quick Look, and copies paths. Raycast adds content search, a recently used files list, folder navigation and sorting, and a metadata panel. Shad has fixed search roots and exclusions. It lacks user-defined scopes, ignore rules, hidden-file and removable-volume settings. |
| Act on a found app or file | **Partial.** Found apps and files can be opened, revealed or copied as paths. File results also offer Quick Look. Shad's favorites and hotkeys apply to its command catalog, so a search result such as Safari cannot be assigned its own launch hotkey. Missing file actions include Share, duplicate, open a folder in Terminal, Quicklink and send to AI. Missing app actions include copying a bundle ID, showing bundle contents and Finder info, hiding, quitting and restarting. |
| Customize and extend the launcher | **Missing.** User-defined aliases, per-command ranking reset and disabling, command deeplinks, compact search-bar-only mode and inline URL handling. Shad has built-in search keywords and a local command catalog. Raycast's extension store, Script Commands, Quicklinks and calculator are additional platform features. |

[Shad Search guide](search-color.md) · [Raycast Search Bar](https://manual.raycast.com/search-bar) · [Raycast File Search](https://manual.raycast.com/file-search) · [Raycast Applications](https://manual.raycast.com/applications) · [Raycast Quickstart](https://manual.raycast.com/quickstart)

## Audio

| Workflow | Coverage |
| --- | --- |
| Keep the built-in microphone ahead of a headset while preferring the headset for playback | **Present.** The input and output lists have independent orders. Shad preserves offline devices by UID, adds new ones at the bottom, falls back on disconnect and reconciles a changed macOS default. The two editions share rankings. Each direction can be turned off. |
| Follow the chosen route everywhere | **Partial.** Shad manages macOS's default input and playback devices while it runs. A device transition can briefly use the OS-selected route. Apps configured to address hardware directly control their own route. Apple's separate sound-effects output has no Shad ranking. The SwitchAudioSource reference also exposes device selection and cycling from a command line. Shad exposes rankings through the palette and its editor. |

**Needs a device test.** Reconnect a lower-ranked Bluetooth headset while an actual recording follows the default microphone. Check both routing and audible continuity. The automated route tests simulate device arrival, departure and failed switches. [Shad audio guide](hardware.md#rank-your-microphones-and-speakers) · [SwitchAudioSource commands](https://github.com/deweller/switchaudio-osx#usage) · [Apple Core Audio system device settings](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem)

## Eject

| Workflow | Coverage |
| --- | --- |
| Safely eject a particular external disk or eject several with one shortcut | **Present.** One action per physical drive, persistent bindings for identifiable disks, a master shortcut, and individual success or failure results. A busy drive allows the batch to continue. The app checks the attachment again before dispatching the system eject. |
| Recognize unusual storage | **Partial by design.** The supported set is directly attached external physical media. Startup stores, internal disks, disk images, network shares, software RAID and multi-store APFS containers are excluded. Ambiguous or unidentified devices use connection-specific bindings. |
| Optional comparison with Jettison | **Missing.** Jettison can eject on sleep or display power-off, remount on wake, mount individual drives and exempt selected disks from automatic handling. The requested manual per-drive and master shortcuts are implemented independently. |

**Needs a device test.** Use expendable external media to verify the physical multi-volume, busy-volume and unplug/reconnect cases. Disk-image tests cannot validate an external disk's detach behavior. [Shad drive guide](hardware.md#leave-with-your-drives) · [Apple Disk Arbitration guide](https://developer.apple.com/library/archive/documentation/DriversKernelHardware/Conceptual/DiskArbitrationProgGuide/ManipulatingDisks/ManipulatingDisks.html) · [Jettison](https://www.stclairsoft.com/Jettison/)

## Color

| Workflow | Coverage |
| --- | --- |
| Pick a screen pixel and copy it | **Present.** The macOS magnifier samples a pixel. Shad converts it to 8-bit sRGB, copies HEX, RGB or HSL, and remembers twelve distinct samples. A recent history entry copies HEX. The most recent sample can be copied again in all three formats. |
| Reuse and organize a design palette | **Missing compared with the Raycast Color Picker extension.** Named groups and durable favorite swatches, bulk palette export, extracting colors from an image, a color wheel, pasted color conversion, color names and additional output formats such as OKLCH and Display P3. |
| Measure display colors | **Missing compared with Apple's Digital Color Meter.** Adjustable sampling aperture with pixel averaging, axis locking, a choice of measurement color space and copying the sample as an image. Color management matters when the design requires preserving a wide-gamut value. |

[Shad Color guide](search-color.md#pick-a-screen-color) · [Raycast Color Picker extension](https://www.raycast.com/thomas/color-picker) · [Apple Digital Color Meter](https://support.apple.com/guide/digital-color-meter/welcome/mac)

## Windows

| Workflow | Coverage |
| --- | --- |
| Arrange a focused window by keyboard | **Present.** Halves, quarters, left/center/right thirds and left/right two-thirds, left/right three-quarters, maximize, center and restore. Shad uses the display containing the largest part of the window. Next and previous display commands move the focused window between monitors. |
| Snap adjacent windows and resize them together | **Present for supported windows.** Drag near an adjacent window to preview an edge match, drop to link, then drag the shared edge. A layout command can also form the link. Links are kept during the session. Accessibility permission, app-specific size limits, full-screen state and Spaces affect which windows can participate. |
| Snap to the display itself and organize several windows | **Missing.** Rectangle's monitor-edge and corner drag targets, move-only and incremental resize commands, finer grids, row/column tiling, cascade and repeated-command layout cycling. Shad's magnetic drop target is another window's edge. |
| Pick and restore multi-window layouts | **Missing.** Windows Snap Assist's suggested companion windows, layout chooser and recallable Snap Groups. FancyZones also provides a custom zone editor, zone-spanning and per-monitor layout assignments. |

[Shad Windows guide](windows.md) · [Rectangle 2.0.4 actions](https://github.com/rxhanson/Rectangle/blob/v2.0.4/Rectangle/WindowAction.swift) · [Rectangle snap areas](https://github.com/rxhanson/Rectangle#how-to-use-it) · [Microsoft Snap](https://support.microsoft.com/en-us/windows/experience/snap-your-windows) · [Microsoft FancyZones](https://learn.microsoft.com/en-us/windows/powertoys/fancyzones)

## Capture and presenter recording

| Workflow | Coverage |
| --- | --- |
| Take a screenshot or record a clip | **Present.** Shad provides commands for area/window, full screen, last area, quick or scrolling capture, OCR including QR, translation, recording an area or display, and stopping. Open images in the editor and movies in Studio from Shad. |
| Use the complete MacShot editor and Studio | **Present through Shad Capture Engine.** The bundled helper is built from MacShot 4.4.0, which matched the installed MacShot version and the latest upstream release on the audit date. It retains upstream annotations, redaction, multi-display capture, beautification, history, export formats and provider uploads. Studio supplies trimming, recording backgrounds, pointer/zoom editing, camera tracks, local captions and SRT export. The editors retain their native UI. The embedded build has its own bundle identity, settings and history. Shad installers update it. Individual MacShot auto-updates and access to history in a separate MacShot installation are unavailable. |
| Trigger every capture action directly from Shad | **Partial.** Record GIF, capture delay, open or pin from clipboard, and extra editor/Studio settings live in the helper’s menu or editor. Open the capture engine from Shad to reach them. The helper’s `shadcapture://` dispatcher exposes a subset of its native commands. Its custom language selection and translations apply to the helper's UI. |
| Record a presenter over a screen or app window | **Present.** Shad's recorder selects a camera and optional default microphone, composites a circular, square or rounded-square image into the exported MP4, and supports sizing, repositioning, mirroring, chroma key and person cutout. Adjust the overlay in the controller preview while recording. |
| Match the full Loom desktop recording flow | **Partial.** The presenter path has a 1920-pixel longest-side cap. Directly dragging the live desktop bubble, camera-only mode, decorative frames, custom virtual background images, camera filters and a Loom-style hosted video link are absent. For area capture, system audio and a separately editable camera track, start a **MacShot recording** instead. Importing a flattened presenter MP4 into Studio cannot recreate its camera track. |

**Verification limit.** The export test reads back movie frames and audio produced from controlled samples. That test cannot establish camera discovery, permission behavior, sustained recording performance or microphone quality on every Mac. Optional upload services require accounts or network access and were reviewed through their upstream implementation. [Shad Capture](capture.md) · [Shad presenter recorder](camera.md) · [MacShot release](https://github.com/sw33tLie/macshot/releases/tag/v4.4.0) · [MacShot command dispatcher](https://github.com/sw33tLie/macshot/blob/v4.4.0/macshot/AppDelegate.swift) · [Loom for macOS](https://support.atlassian.com/loom/docs/get-started-with-loom-for-macos/) · [Loom camera frames](https://support.atlassian.com/loom/docs/add-a-frame-to-your-camera-bubble/)

## Clipboard

| Workflow | Coverage |
| --- | --- |
| Inspect an entry as in the reference recording | **Present.** A hotkey opens history with an item preview and searchable actions. The inspector shows source when available, type, copy times, formats and size, plus dimensions for images, counts for text, paths for files and member counts for groups. The supplied recording shows image actions around 9–14 seconds and text actions around 18–37 seconds. |
| Reuse, edit and manage entries | **Present.** Paste to the previous app, paste and keep the window open, copy, select a paste format, share, edit text, rename, pin, save as a file or named text snippet, and delete one, recent or all entries. Image actions include Open With, Quick Look, reveal, annotate in Preview, and local OCR/QR extraction. Links, emails, files, colors and JSON have type-specific actions. Multiple items from one copy are preserved as a group within size limits. |
| Preserve arbitrary clipboard formats | **Partial.** Shad retains supported source representations. File promises, remote clipboard markers, transient/private types and unsupported or oversized entries are excluded. A single oversized original image can fall back to PNG if it fits. The app records the pasteboard’s source tag when available and otherwise uses the foreground application observed at copy time. Shad keeps up to 200 history entries, 100 MiB total and 16 MiB per entry. |
| Customize history collection and paste behavior | **Partial.** A shared settings window supports age-based retention, preserves pins and snippets, and excludes selected apps. Missing options include OCR enable/speed settings, immediate Apple Universal Clipboard ingestion, remote link cards, choosing the default Return action, always pasting as plain text, and an option to promote used entries. Shad has pause/resume, built-in private-source exclusions, automatic local OCR and explicit plain-text paste. |
| Paste a sequence and reuse snippets | **Partial.** Individual items and saved text snippets can be pasted repeatedly. Raycast's sequential-paste cursor, timeout/newline preferences and reset command are absent. Shad snippets lack keyword expansion, placeholders, tags and import/export. |
| Ask AI about history | **Partial.** Shad accepts a selected item as context on eligible Macs, with a manual browser handoff available. Raycast's Ask Clipboard can search history and edit entries across the store. Shad's conversation is scoped to the selected entry. |

[Shad Clipboard guide](clipboard.md) · [Raycast Clipboard History and settings](https://manual.raycast.com/clipboard-history) · [Raycast Snippets](https://manual.raycast.com/snippets)

## Mouse

| Workflow | Coverage |
| --- | --- |
| Open an Actions Ring and select an app-specific shortcut | **Present.** An eight-slot dial opens near the pointer. Four slots are universal and four follow the active application. Users can name and record shortcuts, learn a mouse or keyboard trigger, tap then click, or hold and release when the triggers are separate. |
| Hold a mouse button and gesture | **Present.** Up, down, left and right are configurable, with app-specific overrides and an adjustable movement threshold. A shared button distinguishes a tap from a directional gesture. |
| Use the advanced Options+ ring and device integrations | **Missing.** Nested action folders, adjustable parameter bubbles, plugin-provided commands and profiles, and device-specific haptics. Shad emits recorded shortcuts. Bindings are shared across mice that send the same button number. A firmware-only control needs the device driver to expose an event to macOS. |

**Needs a device test.** Event fixtures verify gesture direction, app targeting and dial selection. Test a physical vendor-remapped key for sustained key-down and release before relying on it for hold gestures. [Shad Mouse guide](mouse.md) · [Logitech Actions Ring](https://support.logi.com/hc/en-us/articles/17844647906967-Logi-Options-Actions-Ring) · [Logitech folder walkthrough](https://www.youtube.com/watch?v=SX2-dDLjGCM) · [Logitech gestures](https://www.logitech.com/en-us/discover/a/mouse-gestures-setup) · [MX Master 4 haptics](https://support.logi.com/hc/en-001/articles/34335429816727-Haptic-Feedback-MX-Master-4)

## Rechecking a change

The [feature sources](../Sources/Features) and [automated tests](../Tests) are the implementation evidence for the Shad columns. Run `./scripts/test.sh` for regressions and `./scripts/verify-packages.sh` after packaging. When closing a gap, exercise it through the normal suite and standalone entry points, then update its row with the behavior users can expect. For device-specific cases, record the macOS version, device and observed result separately from simulated test results.
