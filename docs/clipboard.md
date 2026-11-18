# Clipboard History

Press **Control + Option + Command + V** to open your history from any app. The same shortcut works in Shad Tools and Shad Clipboard. You can also choose **Clipboard History** in the suite or click the standalone app’s menu bar icon. To change the shortcut, open Shad’s shortcut settings and select **Clipboard History**.

![Clipboard history with text entries and an image preview, shown with example data](clipboard-history.jpg)

## Find and reuse a copy

Copy text or an image in another app while Shad is running. Open Clipboard History to see your newest copies first. Type a word or phrase to search the full text, or filter the list by type. Use **↑** and **↓** to preview an entry.

- **Return** restores the selected entry and pastes it into the app you were using. To grant Accessibility access for direct paste, use **History actions (…) → Enable Direct Paste…** and follow the macOS prompt for the Shad edition you are running. Without access, the entry is copied and you can press **⌘V** yourself.
- **⌘Return** puts the entry on the system clipboard for pasting elsewhere.
- **Escape** closes history. **⌘Delete** removes the selected item. Use **History actions (…)** to pause collection or clear all saved entries.

## What Shad keeps

History begins with the next copy after Shad starts. Text is saved as plain text and images as PNG. Repeated copies of the same content move to the top. Both editions share the same per-user history on this Mac. The store keeps up to 200 entries and 100 MiB of content, with a 16 MiB limit per entry. Older entries are removed first when a limit is reached.

Shad skips copies marked concealed or transient, including those marked by password managers. Ordinary text can still contain sensitive information, so you can pause history before copying it. On macOS versions that ask for clipboard access, choose **Always Allow** for continuous recording of new copies. Shad keeps collecting with the history window closed. To collect after a restart, enable **Start at login** in the edition you use. [Apple’s pasteboard access settings](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum/default)
