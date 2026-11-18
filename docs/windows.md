# Window layouts and magnetic resizing

Focus the window you want to arrange, open Shad Tools or Shad Windows, and search for **Left Half**, **Top Right Quarter** or another layout. The first window command requests macOS Accessibility access. Enable the installed app under **System Settings → Privacy & Security → Accessibility**, then run the command again. **Window Control Permission** opens that settings pane.

## Layouts

| Search for | Result |
| --- | --- |
| Left Half, Right Half, Top Half, Bottom Half | Fill half of the current display's work area. |
| Top Left Quarter, Top Right Quarter, Bottom Left Quarter, Bottom Right Quarter | Tile in a corner. |
| Left Third, Center Third, Right Third | Fill one vertical third. |
| Left Two Thirds, Right Two Thirds | Fit a wide window next to a one-third window. |
| Left Three Quarters, Right Three Quarters | Give one window most of the display. |
| Maximize Window | Fill the space available around the menu bar and Dock. |
| Center Window | Center the window on its display, preserving its size when it fits. |
| Restore Window Size and Position | Return the focused window to its frame before the most recent Shad layout change. |

Press **Control + Option + Command** with a left, right, up or down arrow to tile to that half. To bind another layout, select its command in the palette and press **Command + K**. When a window straddles displays, Shad uses the display containing the largest share of its frame.

## Snap two windows together

1. With magnetic windows enabled, drag a window by its title bar toward another window. Align part of their edges. Within 14 points, an accent-colored outline previews the drop.
2. Release the mouse to snap. You can also run **Left Half** on one window and **Right Half** on another to link their shared edge.
3. Drag that shared edge. The adjacent window grows or shrinks as you drag, keeping its far edge in place. Layout commands can move the shared edge too. For example, run **Left Three Quarters** on the left window.
4. Move a window away to detach it. Holding **Shift** while dropping bypasses magnetic snapping and releases its existing links. **Turn Off Magnetic Windows** disables previews and linked resizing.

Links work between standard, resizable windows visible on the current Space. App-defined minimum sizes, fixed-size dialogs and native full-screen mode can limit placement. Link state lasts until you detach the windows, disable magnetism or quit the app. Screen layouts and shortcut assignments are independent of these links.

## Design references

The keyboard layouts follow conventions documented by Rectangle. The implementation uses macOS Accessibility window attributes. [Rectangle](https://github.com/rxhanson/Rectangle) · [Apple Accessibility APIs](https://developer.apple.com/documentation/applicationservices/axuielement_h)

The drag preview and shared-divider behavior draw on macOS window tiling demonstrations and Microsoft's Snap guide. [MacMost tiling tutorial](https://macmost.com/window-tiling-in-macos-sequoia.html) · [Microsoft Snap guide](https://support.microsoft.com/en-us/windows/experience/snap-your-windows)
