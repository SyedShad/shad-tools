# Search and color

## Search your Mac

Open the palette and type an app, command, filename, or folder name. Use the arrow keys to select a result and Return to open it. For example, `msg` finds Messages, `ss` finds System Settings, and a complete path such as `~/Downloads` opens that location in Finder. Commands can also match a tool name or an alias such as `eyedropper`.

Press **⌘K** on a file result for **Quick Look**, **Show in Finder** or **Copy Path**.

The app catalog covers Applications, System Applications, the system utilities, and your user Applications folder. It refreshes in the background as you use the launcher. App search works even when Spotlight indexing is disabled.

File results appear after two characters. Shad Tools asks Spotlight for names in your home folder and displays up to 30 matches from the most recently modified candidates. Hidden directories, application bundle contents, `~/Library`, and `node_modules` are filtered from these results. Exact paths can open accessible items outside this scope. If a document never appears by name, check whether Spotlight indexes its folder in System Settings.

## Pick a screen color

1. Run **Pick Screen Color as HEX**, **RGB**, or **HSL**.
2. Move the macOS magnifier over the pixel you want, then click. Escape cancels sampling.
3. Paste the result. For example, a bright blue pixel copies as `#0000FF`, `rgb(0, 0, 255)`, or `hsl(240, 100%, 50%)`.

The picker converts screen samples to 8-bit sRGB. Search for **Copy Last Color** to copy the latest sample in another format. Search for **recent color** to retrieve one of the last 12 distinct samples as HEX. The samples are saved in the app’s local preferences. **Clear Color History** removes them. The Color edition and the suite each keep their own history.

## Design references

The keyboard workflow follows the launcher pattern shown in the Raycast quickstart and file-search walkthrough. [Raycast Quickstart](https://manual.raycast.com/quickstart) · [Raycast File Search](https://manual.raycast.com/file-search)

The macOS implementation uses Spotlight metadata queries and AppKit’s system sampler. [Apple’s Spotlight metadata guide](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html) · [NSColorSampler](https://developer.apple.com/documentation/appkit/nscolorsampler)
