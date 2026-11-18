import SwiftUI

struct AudioPriorityEditor: View {
    @ObservedObject var tool: AudioTool
    private var route: AudioRoute { tool.editorRoute }

    var body: some View {
        let list = tool.lists[route] ?? AudioPriorityList()
        VStack(alignment: .leading, spacing: 0) {
            Picker("Device type", selection: $tool.editorRoute) {
                Text("Input").tag(AudioRoute.input)
                Text("Output").tag(AudioRoute.output)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 205).frame(maxWidth: .infinity).padding(.vertical, 16)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use " + route.rawValue + " priorities").font(.headline)
                    Text("The highest connected device in this list wins.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Use " + route.rawValue + " priorities", isOn: Binding(get: { list.enabled }, set: { tool.setEnabled($0, for: route) }))
                    .labelsHidden().toggleStyle(.switch)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(list.devices.enumerated()), id: \.element.uid) { index, entry in
                        row(entry, index: index, count: list.devices.count)
                        Divider()
                    }
                    if list.devices.isEmpty { Text("Connect an audio device to add it to the list.").foregroundStyle(.secondary).padding() }
                }
            }
            if let error = tool.errors[route] {
                Text(error).foregroundStyle(.orange).padding(12)
            }
        }.frame(minWidth: 420, minHeight: 260)
    }

    private func row(_ entry: RankedAudioDevice, index: Int, count: Int) -> some View {
        let live = tool.devices.first { $0.uid == entry.uid && $0.routes.contains(route) }
        let active = live != nil && live?.id == tool.current[route]
        return HStack(spacing: 13) {
            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
            Image(systemName: route.symbol).foregroundStyle(active ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                Text(active ? "Current default" : live == nil ? "Disconnected" : "Connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { tool.move(entry.uid, in: route, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0).accessibilityLabel("Move " + entry.name + " up")
            Button { tool.move(entry.uid, in: route, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index + 1 >= count).accessibilityLabel("Move " + entry.name + " down")
        }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 48)
        .contextMenu {
            Button("Make First") { tool.promote(entry.uid, in: route) }
            if live == nil { Button("Forget Device") { tool.forget(entry.uid, in: route) } }
        }
    }
}
