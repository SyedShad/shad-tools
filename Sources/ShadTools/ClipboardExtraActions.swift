import AppKit

enum ClipboardExtraActions {
    @MainActor static func actions(for entry: ClipboardEntry, content: ClipboardContent?, tool: ClipboardTool) -> [ClipboardUIAction] {
        guard let content else { return [] }
        let attach = entry.kind == .image || entry.kind == .files
        var actions = [ClipboardUIAction(id: "chat", title: attach ? "Attach to AI Chat" : "Send to AI Chat",
                                         symbol: "bubble.left.and.bubble.right") {
            ClipboardChat.shared.show(entry: entry, content: content, tool: tool)
        }]
        guard case .text(let text) = content else { return actions }
        if entry.kind == .color, let parsed = ClipboardColor(css: text) {
            for (name, value) in [("HEX", parsed.hex), ("RGB", parsed.rgb), ("HSL", parsed.hsl)] {
                actions.append(ClipboardUIAction(id: "color." + name, title: "Copy Color as " + name, symbol: "paintpalette") { tool.copyText(value) })
            }
        }
        if possibleJSON(text) {
            // Parse only on invocation. Building or filtering the action menu should be cheap for large entries.
            actions.append(ClipboardUIAction(id: "formatted-json", title: "Copy Formatted JSON", symbol: "curlybraces") {
                Task {
                    let result = await Task.detached(priority: .userInitiated) { formatJSON(text) }.value
                    if let result { tool.copyText(result) }
                    else { Feedback.show("This item doesn’t contain valid JSON.") }
                }
            })
        }
        return actions
    }

    static func possibleJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    static func formatJSON(_ text: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let bytes = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
