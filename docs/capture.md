# Screenshots and screen recording

Open **Screen Capture** in Shad Tools or install **Shad Capture** on its own. The palette starts common tasks directly. For example, **Capture Area or Window** opens a frozen view of the desktop. Drag a rectangle to select a region, or hover over a window and click it. Use the annotation toolbar, then copy or save the image. Escape cancels.

Shad includes the signed, full edition of MacShot 4.4.0. Its native editors, Studio and menu bar run as MacShot. Choose **Open MacShot**, then click its menu bar icon for additional actions such as **Record GIF**, delayed capture, **Open from Clipboard** and **Pin from Clipboard**. The first capture can prompt for MacShot's Screen Recording permission. On a Mac that already runs a compatible MacShot signed by its developer, the palette sends the command to that process. MacShot permits one instance per user and shares its existing preferences and history.

## Feature guide

| Task | Start here | Available controls |
| --- | --- | --- |
| Region, window or entire display | **Capture Area or Window**, **Capture Full Screen**, **Capture Last Area**, **Quick Capture** | Window snap, edge snap, exact pixel size, aspect ratio, cross-display capture, repeat the last selection and quick save/copy. The menu bar offers a 3, 5, 10 or 30 second delay. |
| Long page or wide canvas | **Capture Scrolling Content** | Choose the region, then scroll vertically or horizontally. The preview follows the stitched image. Return or ⌘C finishes. |
| Mark up a screenshot | Capture an area or **Open Image in Capture Editor** | Arrows, rectangles, ellipses, rich text, pencil, marker, numbering, stamps, emoji, ruler, loupe, highlight, color sampling, rotation, alignment and editable layers. |
| Hide private details | Editor → Censor | Blur, pixelate, fill or erase a region. Automatic redaction can locate sensitive text, faces and people. Review the result before sharing. |
| Read text, codes or another language | **Extract Text or QR Code**, **Translate Text on Screen** | OCR, QR and barcode actions, copy, translate, search or draw the translation over the original. |
| Compose and style an image | Capture editor → Add Capture, Crop, Beautify or Adjust | Layer more captures or pasted images, zoom, flip, invert, apply backgrounds, borders, padding, shadows and color adjustments. System-dependent options include foreground extraction on macOS 14+ and mesh gradients on macOS 15+. |
| Find and reuse captures | **Recent Captures**, editor or floating thumbnail | Browse history, reopen editable annotations, pin previews, drag files, reveal, save or copy. |
| Record a clip or GIF | **Record Screen Area**, **Record Full Screen**, MacShot menu → **Record GIF** | Area or display, configurable frame rate, system audio, microphone, cursor/click effects and live drawing. End a MacShot take with **Stop Screen Recording** or the MacShot recording control. |
| Edit a recording | Open the resulting clip in Studio or choose **Open Video in Studio** for an MP4, MOV or M4V | Timeline trimming, cuts, speed, freeze, titles, censor, pointer styling, zoom, background framing, editable webcam track, keystroke labels, waveform, captions, SRT, undo, autosave and export. Editable camera/pointer data requires a MacShot take that saved those tracks. |
| Export or upload | Editor, Studio or thumbnail → Save, Copy or Upload | Image formats include PNG, JPEG, HEIC, WebP and AVIF. Studio exports video or GIF. MacShot includes Google Drive, imgbb and S3-compatible upload providers. Uploads use the selected provider and its credentials or hosting settings. |
| Adjust capture behavior | **Capture Settings** | Configure capture and editor shortcuts, language, filenames and date folders, toolbar/menu behavior, capture feedback, output and recording preferences. Palette URL actions require **Enable macshot:// URL scheme** in MacShot Settings. |

These features come from the bundled MacShot release. The upstream feature and release guides describe the editor tools, keyboard shortcuts and version-specific options. [MacShot 4.4.0 feature guide](https://github.com/sw33tLie/macshot/blob/v4.4.0/README.md) · [Studio release notes](https://github.com/sw33tLie/macshot/releases/tag/v4.4.0) · [MacShot privacy policy](https://github.com/sw33tLie/macshot/blob/v4.4.0/PRIVACY.md)

## Record yourself over a screen or window

Choose **Record Screen with Camera** in the Shad palette. Select the display or window, your built-in front camera or another camera, and the microphone option. Choose the overlay shape, position and size. Green-screen keying removes green behind the speaker. Person cutout uses foreground segmentation. Start the recording, select an MP4 destination, then choose **Stop and Save Camera Recording** in the palette or click the red Shad recording control. The presenter is composited into the exported movie. You can then open the MP4 in Studio.

macOS manages screen, camera and microphone permissions for the Shad app doing the presenter recording. Microphone access is used when narration is enabled. MacShot's native recording mode has its own permissions and supports separate camera tracks for post-recording edits.

## Distribution

The suite and the standalone Capture installer contain the same signed helper at `Contents/Helpers/macshot.app`. The other editions omit it. A Shad installer updates the bundled helper as part of the host app. The independent MacShot application can continue using its own update workflow. To build the packages from source, the packaging script obtains the pinned upstream disk image and source, verifies their SHA-256 digests and checks the original helper's Developer ID and universal binary.

The GPLv3 source snapshot and notices are included at `Contents/Resources/CaptureSources`. [Bundled licenses and sources](../ThirdParty/MacShot/NOTICE.md)
