import AppKit
import SwiftUI

private struct QueryField: NSViewRepresentable {
    @ObservedObject var model: PaletteModel
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PaletteModel
        init(_ model: PaletteModel) { self.model = model }
        @MainActor func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSTextField { model.query = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 21, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search")
        model.refocus = { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != model.query { field.stringValue = model.query }
        field.placeholderString = model.prompt
    }
}

@MainActor
private final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 150 }

    func icon(_ path: String) -> NSImage {
        let key = path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct CommandIcon: View {
    let command: ToolCommand
    let edition: Edition
    var body: some View {
        Group {
            if let prefix = ["search.app.", "search.file."].first(where: { command.id.hasPrefix($0) }) {
                Image(nsImage: FileIconCache.shared.icon(String(command.id.dropFirst(prefix.count))))
                    .resizable().aspectRatio(contentMode: .fit)
            } else if command.id.hasPrefix("color.history."),
                      let color = SampledColor(hex: String(command.id.dropFirst("color.history.".count))) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.2)))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [edition.tint, edition.tint.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: command.symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                }
            }
        }.frame(width: 35, height: 35).accessibilityHidden(true)
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    private var accent: Color { Edition.suite.tint }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium)).foregroundStyle(accent)
                QueryField(model: model).frame(maxWidth: .infinity).frame(height: 30)
                Button { model.settings ? model.back() : model.showSettings() } label: {
                    Image(systemName: model.settings ? "chevron.backward" : "slider.horizontal.3").font(.system(size: 17))
                }.buttonStyle(.plain).accessibilityLabel(model.settings ? "Back" : "Settings").help(model.settings ? "Back" : "Settings (⌘,)")
            }.padding(.horizontal, 23).frame(height: 72)
            Divider()
            HStack {
                if model.scope != nil && model.edition == .suite || model.settings {
                    Button { model.back() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).accessibilityLabel("Back")
                }
                Text(model.query.isEmpty ? model.title : "Results").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.settings {
                    Button { model.toggleLogin() } label: {
                        Label("Start at login", systemImage: model.loginEnabled ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(.plain).help("Start this edition when you sign in to your Mac")
                } else if model.scope != nil || !model.query.isEmpty {
                    Text("\(model.rows.count)").monospacedDigit().font(.caption)
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 21).frame(height: 35)
            if model.rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No matching commands").font(.headline)
                    Text("Try a different name or a shorter search.").foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, command in
                                row(command, index: index).id(command.id)
                            }
                        }.padding(.horizontal, 9).padding(.bottom, 9)
                    }.onChange(of: model.selected) { value in
                        if model.rows.indices.contains(value) { proxy.scrollTo(model.rows[value].id) }
                    }.onChange(of: model.rows.first?.id) { _ in
                        if let current = model.current { proxy.scrollTo(current.id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(accent)
                Text(model.edition.title).fontWeight(.semibold)
                Spacer()
                if let command = model.current {
                    if model.canRecord(command) && !model.settings {
                        Button("Shortcut ⌘K") { model.record(command) }.buttonStyle(.plain).foregroundStyle(.secondary)
                        Divider().frame(height: 12)
                    }
                    Button { model.execute(command) } label: {
                        HStack(spacing: 5) {
                            Text(model.settings ? "Set shortcut" : command.id.hasPrefix("group.") ? "Open" : "Run")
                            Image(systemName: "return")
                        }
                    }.buttonStyle(.plain)
                }
            }.font(.system(size: 12)).padding(.horizontal, 18).frame(height: 39)
        }.background(.regularMaterial)
        .overlay {
            if let target = model.recording {
                ZStack {
                    Rectangle().fill(.ultraThickMaterial).onTapGesture {}
                    VStack(spacing: 13) {
                        Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(accent)
                        Text(model.rows.first(where: { $0.id == target })?.title ?? "Keyboard shortcut").font(.title3.weight(.semibold))
                        Text("Press a key with Control, Option or Command.").foregroundStyle(.secondary)
                        if let chord = model.shortcuts.binding(target) { Text(chord.label).font(.title3.monospaced()) }
                        if let note = model.note { Text(note).foregroundStyle(.orange).multilineTextAlignment(.center) }
                        HStack {
                            Button("Remove shortcut") { model.save(nil) }
                            Button("Cancel") { model.back() }
                        }.padding(.top, 6)
                    }.padding(32)
                }
            } else if let note = model.note {
                VStack { Spacer(); Text(note).padding().background(.regularMaterial, in: Capsule()).onTapGesture { model.note = nil } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.14), lineWidth: 1))
    }

    private func row(_ command: ToolCommand, index: Int) -> some View {
        let item = Edition.allCases.first(where: { $0.group == command.group }) ?? .search
        return Button {
            model.selected = index
            model.execute(command)
        } label: {
            HStack(spacing: 13) {
                CommandIcon(command: command, edition: item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(command.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if model.shortcuts.conflicts.contains(command.id) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Shortcut is in use. Choose another in Settings.")
                }
                if let binding = model.shortcuts.binding(command.id) {
                    Text(binding.label).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                } else if command.id.hasPrefix("group.") {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                } else if model.settings {
                    Text("Set shortcut").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(command.group).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).frame(height: 54)
                .background(index == model.selected ? accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint(command.subtitle)
        .contextMenu {
            if model.canRecord(command) { Button("Set keyboard shortcut…") { model.selected = index; model.record(command) } }
        }
    }
}
