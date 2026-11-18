import AppKit
import SwiftUI

private final class PaletteTextField: NSTextField {
    var focusOnMount = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusOnMount, let window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

private struct QueryField: NSViewRepresentable {
    @ObservedObject var model: PaletteModel
    var searchingActions = false
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PaletteModel
        let searchingActions: Bool
        init(_ model: PaletteModel, searchingActions: Bool) {
            self.model = model
            self.searchingActions = searchingActions
        }
        @MainActor func controlTextDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = .labelColor
        }
        @MainActor func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            if searchingActions { model.actionQuery = field.stringValue }
            else { model.query = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model, searchingActions: searchingActions) }
    func makeNSView(context: Context) -> NSTextField {
        let field = PaletteTextField()
        field.font = .systemFont(ofSize: searchingActions ? 15 : 21, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.focusOnMount = searchingActions
        field.setAccessibilityLabel(searchingActions ? "Search actions" : "Search")
        if !searchingActions {
            model.refocus = { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let text = searchingActions ? model.actionQuery : model.query
        if field.stringValue != text { field.stringValue = text }
        let placeholder = searchingActions ? "Search for actions…" : model.prompt
        if field.placeholderAttributedString?.string != placeholder {
            let ink = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(srgbRed: dark ? 0.60 : 0.42, green: dark ? 0.60 : 0.42, blue: dark ? 0.60 : 0.42, alpha: 1)
            }
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: ink, .font: field.font ?? NSFont.systemFont(ofSize: 21)])
        }
    }
}

@MainActor
private final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSURL, NSImage>()
    private init() { cache.countLimit = 150 }
    func icon(_ url: URL) -> NSImage {
        if let image = cache.object(forKey: url as NSURL) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

private struct CommandIcon: View {
    let command: ToolCommand
    private var tile: Color {
        switch command.group {
        case "Search": return Color(red: 0.23, green: 0.56, blue: 0.98)
        case "Audio": return Color(red: 0.56, green: 0.36, blue: 0.94)
        case "Drives": return Color(red: 0.96, green: 0.55, blue: 0.17)
        case "Color": return Color(red: 0.94, green: 0.29, blue: 0.54)
        case "Windows": return Color(red: 0.15, green: 0.67, blue: 0.76)
        case "Capture": return Color(red: 0.94, green: 0.29, blue: 0.34)
        case "Clipboard": return Color(red: 0.18, green: 0.64, blue: 0.46)
        case "Mouse": return Color(red: 0.28, green: 0.50, blue: 0.85)
        default: return .gray
        }
    }
    var body: some View {
        Group {
            if let url = command.fileURL {
                Image(nsImage: FileIconCache.shared.icon(url)).resizable().aspectRatio(contentMode: .fit)
            } else if command.id.hasPrefix("color.history."),
                      let color = SampledColor(hex: String(command.id.dropFirst("color.history.".count))) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.18)))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tile.gradient)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                    Image(systemName: command.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }.frame(width: 24, height: 24).accessibilityHidden(true)
    }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .frame(minWidth: 17, minHeight: 18)
            .padding(.horizontal, text.count > 1 ? 3 : 0)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.16), lineWidth: 0.7))
            .accessibilityHidden(true)
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let corner = RoundedRectangle(cornerRadius: 25, style: .continuous)
    private var surface: Color { scheme == .dark ? Color(white: 0.235) : Color(white: 0.969) }
    private var selection: Color { scheme == .dark ? .white.opacity(0.10) : .black.opacity(0.075) }
    private var secondary: Color { scheme == .dark ? Color(white: 0.72) : Color(white: 0.36) }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                if model.rows.isEmpty { emptyState }
                else { results }
            }
            .accessibilityHidden(model.actionTarget != nil || model.recording != nil)

            if model.actionTarget == nil && model.recording == nil {
                footer
            }
            if let command = model.actionCommand {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.closeActions() }
                actionPanel(for: command)
            }
            if let target = model.recording { recorder(target) }
            else if let note = model.note {
                Text(note).font(.callout).multilineTextAlignment(.center).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24).padding(.bottom, 56)
                    .onTapGesture { model.note = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { surface.opacity(reduceTransparency ? 1 : 0.93).background(.regularMaterial) }
        .clipShape(corner)
        .overlay(corner.strokeBorder(.primary.opacity(0.12), lineWidth: 0.65).allowsHitTesting(false))
    }

    private var header: some View {
        HStack(spacing: 12) {
            if (model.scope != nil && model.edition == .suite) || model.settings {
                Button { model.selectScope(model.edition == .suite ? nil : model.edition) } label: {
                    Image(systemName: "chevron.backward").frame(width: 23, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Back")
            } else {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 20, weight: .medium)).frame(width: 23, height: 24).accessibilityHidden(true)
            }
            QueryField(model: model).frame(maxWidth: .infinity).frame(height: 29)
            if model.canJumpToCapture {
                Button { model.selectScope(.capture) } label: {
                    HStack(spacing: 8) { Text("Capture"); Keycap(text: "⇥") }
                }.buttonStyle(.plain).help("Open Capture (Tab)")
            } else if model.settings {
                Menu {
                    Picker("Appearance", selection: $model.appearance) {
                        ForEach(PaletteAppearance.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }.menuStyle(.borderlessButton).fixedSize().help("Palette appearance")
                Button { model.toggleLogin() } label: {
                    Label("Start at login", systemImage: model.loginEnabled ? "checkmark.circle.fill" : "circle")
                }.buttonStyle(.plain)
            }
        }
        .font(.system(size: 14, weight: .medium)).foregroundStyle(secondary)
        .padding(.horizontal, 18).frame(height: 68)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("palette-top")
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, command in
                        if let text = model.sectionHeaders[command.id] {
                            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
                                .accessibilityAddTraits(.isHeader).padding(.leading, 10)
                                .frame(height: 28, alignment: .center)
                        }
                        row(command, index: index).id(command.id)
                    }
                }.padding(.horizontal, 9)
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 53)
            .onChange(of: model.selected) { index in
                guard model.rows.indices.contains(index) else { return }
                if index == 0 { proxy.scrollTo("palette-top", anchor: .top) }
                else { proxy.scrollTo(model.rows[index].id) }
            }
            .onChange(of: model.query) { _ in proxy.scrollTo("palette-top", anchor: .top) }
            .onChange(of: model.scope) { _ in proxy.scrollTo("palette-top", anchor: .top) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundStyle(secondary)
            Text("No results").font(.system(size: 16, weight: .semibold))
            Text("Try another name or a shorter search.").font(.system(size: 13)).foregroundStyle(secondary)
            Spacer()
        }.frame(maxWidth: .infinity).padding(.bottom, 34)
    }

    private func row(_ command: ToolCommand, index: Int) -> some View {
        Button {
            model.selected = index
            model.execute(command)
        } label: {
            HStack(spacing: 12) {
                CommandIcon(command: command)
                Text(command.title).font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).layoutPriority(2)
                if command.kind != "Application" {
                    Text(command.subtitle).font(.system(size: 14)).lineLimit(1)
                        .truncationMode(command.fileURL == nil ? .tail : .middle).foregroundStyle(secondary)
                }
                Spacer(minLength: 5)
                if model.shortcuts.conflicts.contains(command.id) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("Shortcut in use. Choose another in Settings.")
                }
                if let binding = model.shortcuts.binding(command.id) {
                    Keycap(text: binding.label).foregroundStyle(secondary)
                } else {
                    Text(model.settings ? "Set shortcut" : command.kind)
                        .lineLimit(1).font(.system(size: 14)).foregroundStyle(secondary).layoutPriority(1)
                }
            }.padding(.horizontal, 10).frame(height: 42)
                .background(index == model.selected ? selection : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(command.subtitle)
        .accessibilityLabel(command.title).accessibilityValue(command.subtitle)
        .accessibilityAddTraits(index == model.selected ? .isSelected : [])
        .contextMenu {
            Button("Actions…") { model.selected = index; model.toggleActions() }
            if model.canRecord(command) { Button("Set Keyboard Shortcut…") { model.selected = index; model.record(command) } }
        }
    }

    private var footer: some View {
        HStack {
            Button { model.settings ? model.back() : model.showSettings() } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 15, weight: .medium)).frame(width: 40, height: 40)
            }.buttonStyle(.plain).background(chrome, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.14), lineWidth: 0.7).allowsHitTesting(false))
                .accessibilityLabel(model.settings ? "Close settings" : "Settings").help("Settings (⌘,)")
            Spacer()
            if let command = model.current {
                HStack(spacing: 15) {
                    Button { model.execute(command) } label: {
                        HStack(spacing: 8) {
                            Text(model.title(.run, for: command)).fontWeight(.medium)
                            Keycap(text: "↵").foregroundStyle(secondary)
                        }
                    }.buttonStyle(.plain)
                    Button { model.toggleActions() } label: {
                        HStack(spacing: 3) {
                            Text("Actions").padding(.trailing, 4)
                            Keycap(text: "⌘")
                            Keycap(text: "K")
                        }
                    }.buttonStyle(.plain).foregroundStyle(secondary).help("Open actions (⌘K)")
                }
                .font(.system(size: 13)).padding(.horizontal, 15).frame(height: 40)
                .background(chrome, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.15), lineWidth: 0.7).allowsHitTesting(false))
            }
        }
        .padding(.horizontal, 9).padding(.bottom, 8).padding(.top, 7)
        .background(LinearGradient(colors: [surface.opacity(0), surface.opacity(0.91), surface],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    private var chrome: Color { scheme == .dark ? Color(white: 0.30) : Color(white: 0.93) }

    private func actionPanel(for command: ToolCommand) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(command.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(secondary)
                .lineLimit(1).padding(.horizontal, 17).frame(height: 34)
            let actions = model.filteredActions
            if actions.isEmpty {
                Text("No matching actions").foregroundStyle(secondary)
                    .font(.callout).padding(.horizontal, 18).frame(height: 42)
            } else {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    Button { model.performAction(action) } label: {
                        HStack(spacing: 11) {
                            Image(systemName: action.symbol).frame(width: 19).accessibilityHidden(true)
                            Text(model.title(action, for: command))
                            Spacer()
                            if action == .run { Keycap(text: "↵").foregroundStyle(secondary) }
                            if action == .settings { Keycap(text: "⌘,").foregroundStyle(secondary) }
                        }.font(.system(size: 14, weight: .medium)).padding(.horizontal, 10).frame(height: 40)
                            .background(index == model.selectedAction ? selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 7)
                    .accessibilityAddTraits(index == model.selectedAction ? .isSelected : [])
                }
            }
            Divider().padding(.top, 7)
            QueryField(model: model, searchingActions: true).frame(height: 25)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .padding(.top, 4)
        .frame(maxWidth: 365).background { chrome.opacity(reduceTransparency ? 1 : 0.94).background(.thickMaterial) }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.primary.opacity(0.19), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func recorder(_ target: String) -> some View {
        ZStack {
            Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture { model.back() }
            VStack(spacing: 13) {
                Image(systemName: "keyboard").font(.system(size: 23)).foregroundStyle(secondary)
                Text(model.rows.first(where: { $0.id == target })?.title ?? "Keyboard shortcut").font(.headline)
                Text("Press a key with Control, Option or Command.").font(.callout).foregroundStyle(secondary)
                if let chord = model.shortcuts.binding(target) { Keycap(text: chord.label) }
                if let note = model.note { Text(note).foregroundStyle(.orange).multilineTextAlignment(.center) }
                HStack {
                    if model.shortcuts.binding(target) != nil { Button("Remove shortcut") { model.save(nil) } }
                    Button("Cancel") { model.back() }
                }.padding(.top, 5)
            }.padding(24).frame(maxWidth: 365).background(chrome, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.15)))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        }
    }
}
