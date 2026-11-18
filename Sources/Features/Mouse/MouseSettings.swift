import ShadCore
import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

private enum MouseSettingsTab: String, CaseIterable { case buttons = "Buttons", dial = "Dial", gestures = "Gestures" }
private struct ProfileApp: Identifiable, Hashable {
    let id: String
    let name: String
}

@MainActor final class MouseSettingsWindow: NSObject, ObservableObject, NSWindowDelegate {
    let profiles: MouseProfiles
    var requestPermission: () -> Void = {}
    var permissionStatus: () -> String = { "" }
    var learn: (@escaping (MouseTrigger?) -> Void) -> Void = { $0(nil) }
    var cancelLearn: () -> Void = {}
    var recordingShortcut: (Bool) -> Void = { _ in }

    @Published fileprivate var tab = MouseSettingsTab.buttons
    @Published fileprivate var apps: [ProfileApp] = []
    @Published fileprivate var app = ProfileApp(id: "", name: "Default for other apps")
    @Published fileprivate var status = ""
    @Published fileprivate var learningDial: Bool?
    @Published fileprivate var slot: MouseSlot?
    @Published fileprivate var draft = MouseDefaults.global[0]
    @Published fileprivate var recording = false
    private var window: NSWindow?
    private var keyMonitor: Any?
    private var learningID = UUID()

    init(profiles: MouseProfiles) { self.profiles = profiles; super.init() }

    func show(app target: NSRunningApplication?) {
        profiles.refresh()
        if let target, let id = target.bundleIdentifier,
           !id.hasPrefix("io.github.syedshad.shadtools.") {
            app = ProfileApp(id: id, name: target.localizedName ?? id)
        }
        refreshApps()
        refreshStatus()
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 510),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "Mouse Tools"
            panel.minSize = NSSize(width: 615, height: 465)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: MouseSettingsView(editor: self, profiles: profiles))
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { refreshStatus(); refreshApps() }
    func windowDidResignKey(_ notification: Notification) { stopRecording(); cancelLearning() }
    func windowWillClose(_ notification: Notification) { cancelLearning(); endEdit() }
    fileprivate func refreshStatus() { status = permissionStatus() }

    private func refreshApps() {
        var found: [String: String] = profiles.configuration.apps.mapValues(\.name)
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            if let id = running.bundleIdentifier, !id.hasPrefix("io.github.syedshad.shadtools.") {
                found[id] = running.localizedName ?? id
            }
        }
        if !app.id.isEmpty { found[app.id] = app.name }
        apps = found.map { ProfileApp(id: $0.key, name: $0.value) }.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    fileprivate func chooseApplication() {
        let picker = NSOpenPanel()
        picker.title = "Choose an Application"
        picker.allowedContentTypes = [.applicationBundle]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        app = ProfileApp(id: id, name: name)
        refreshApps()
    }

    fileprivate func startLearning(_ forDial: Bool) {
        cancelLearning()
        endEdit()
        let token = UUID()
        learningID = token
        learningDial = forDial
        learn { [weak self] trigger in
            guard let self, token == learningID else { return }
            learningDial = nil
            if let trigger { profiles.setTrigger(trigger, forDial: forDial) }
            refreshStatus()
        }
    }

    fileprivate func cancelLearning() {
        guard learningDial != nil else { return }
        learningID = UUID()
        learningDial = nil
        cancelLearn()
    }

    fileprivate func edit(_ which: MouseSlot) {
        guard let action = profiles.action(for: which) else { return }
        cancelLearning()
        draft = action
        slot = which
    }

    fileprivate func save() {
        guard let slot else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { return }
        profiles.assign(draft, to: slot)
        if profiles.error == nil { endEdit() }
    }

    fileprivate func endEdit() { stopRecording(); slot = nil }

    fileprivate func startRecording() {
        if recording { stopRecording(); return }
        recording = true
        recordingShortcut(true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.record(event) == true }
            return handled ? nil : event
        }
    }

    private func record(_ event: NSEvent) -> Bool {
        guard recording, let window, event.window === window else { return false }
        if event.keyCode == 53 { stopRecording(); return true }
        var flags = 0
        for (modifier, bit) in [(NSEvent.ModifierFlags.command, cmdKey), (.shift, shiftKey), (.control, controlKey), (.option, optionKey)] {
            if event.modifierFlags.contains(modifier) { flags |= bit }
        }
        let code = Int(event.keyCode)
        let symbols = [36: "↩", 48: "Tab", 49: "Space", 51: "⌫", 76: "Enter", 115: "Home", 116: "Page Up", 117: "⌦",
                       119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let functionKeys = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        let function = functionKeys.firstIndex(of: code).map { "F" + String($0 + 1) }
        let key = symbols[code] ?? function ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return true }
        draft.shortcut = KeyChord(code, flags, key)
        draft.symbol = "keyboard"
        stopRecording()
        return true
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if recording { recording = false; recordingShortcut(false) }
    }
}

private struct MouseSettingsView: View {
    @ObservedObject var editor: MouseSettingsWindow
    @ObservedObject var profiles: MouseProfiles

    private var config: MouseConfiguration { profiles.configuration }
    private var appID: String? { editor.app.id.isEmpty ? nil : editor.app.id }
    private var appGestures: Bool { appID.flatMap { config.apps[$0]?.usesCustomGestures } == true }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 13) {
                    Image(systemName: "computermouse.fill").font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white).frame(width: 37, height: 37)
                        .background(Color(red: 0.34, green: 0.41, blue: 0.80).gradient, in: RoundedRectangle(cornerRadius: 9))
                    Text("Mouse Tools").font(.title2.weight(.semibold))
                    Spacer()
                    Toggle("Enable Mouse Tools", isOn: Binding(get: { config.enabled }, set: {
                        profiles.setEnabled($0)
                        editor.refreshStatus()
                        if $0 && !editor.status.isEmpty { editor.requestPermission(); editor.refreshStatus() }
                    })).toggleStyle(.switch)
                }.padding(.horizontal, 22).padding(.vertical, 14)
                Divider()
                Picker("Mouse settings", selection: Binding(get: { editor.tab }, set: { editor.cancelLearning(); editor.tab = $0 })) {
                    ForEach(MouseSettingsTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 300).padding(.vertical, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if editor.tab == .buttons { buttons }
                        else if editor.tab == .dial { dial }
                        else { gestures }
                        if let error = profiles.error { Text(error).font(.callout).foregroundStyle(.orange) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.disabled(editor.slot != nil).accessibilityHidden(editor.slot != nil)
            if editor.slot != nil { actionEditor }
        }.frame(minWidth: 600, minHeight: 410)
    }

    @ViewBuilder private var buttons: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Trigger buttons").font(.headline)
            Text("Assign separate buttons, or use the same one to tap for the dial and drag for a gesture.")
                .font(.callout).foregroundStyle(.secondary)
        }
        VStack(spacing: 0) {
            triggerRow(true)
            Divider().padding(.leading, 13)
            triggerRow(false)
        }.background(card)
        if editor.learningDial != nil {
            HStack {
                Text("Press the mouse button or driver shortcut to assign. Escape cancels.").font(.callout)
                Spacer()
                Button("Cancel") { editor.cancelLearning() }
            }
        } else {
            Text("For a one-button mouse, choose Option + Left Click. Use Learn for other mouse buttons or a shortcut assigned by your mouse driver.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !editor.status.isEmpty {
            HStack {
                Image(systemName: "hand.raised")
                Text(editor.status).frame(maxWidth: .infinity, alignment: .leading)
                Button("Allow Access…") { editor.requestPermission(); editor.refreshStatus() }
            }.font(.callout).padding(12).background(card)
        }
    }

    private func triggerRow(_ dial: Bool) -> some View {
        let value = dial ? config.dialTrigger : config.gestureTrigger
        return HStack(spacing: 12) {
            Image(systemName: dial ? "circle.grid.2x2" : "arrow.up.and.down.and.arrow.left.and.right").frame(width: 23).foregroundStyle(.secondary)
            Text(dial ? "Dial button" : "Gesture button").fontWeight(.medium)
            Spacer()
            Menu {
                Button("Middle Click") { profiles.setTrigger(.middle, forDial: dial) }
                Button("Back Button") { profiles.setTrigger(MouseTrigger(button: 3), forDial: dial) }
                Button("Forward Button") { profiles.setTrigger(MouseTrigger(button: 4), forDial: dial) }
                Button("Option + Left Click") { profiles.setTrigger(.optionClick, forDial: dial) }
                Button("Option + Right Click") { profiles.setTrigger(MouseTrigger(button: 1, modifiers: .maskAlternate), forDial: dial) }
            } label: { Text(value.label) }.fixedSize().accessibilityLabel((dial ? "Dial" : "Gesture") + " trigger: " + value.label)
            Button(editor.learningDial == dial ? "Listening…" : "Learn…") { editor.startLearning(dial) }
                .accessibilityLabel(dial ? "Learn dial button" : "Learn gesture button")
        }.padding(.horizontal, 13).frame(height: 51)
    }

    private var appPicker: some View {
        HStack {
            Label("Application", systemImage: "app.dashed").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu(editor.app.name) {
                Button("Default for other apps") { editor.app = ProfileApp(id: "", name: "Default for other apps") }
                Divider()
                ForEach(editor.apps) { app in Button(app.name) { editor.app = app } }
                Divider()
                Button("Choose Application…") { editor.chooseApplication() }
            }.fixedSize().accessibilityLabel("Application profile: " + editor.app.name)
        }
    }

    @ViewBuilder private var dial: some View {
        appPicker
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Universal · Left").font(.headline)
                actionGroup(config.global) { .universal($0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Application · Right").font(.headline)
                actionGroup(config.appActions(for: appID)) { .application(bundleID: appID, name: editor.app.name, index: $0) }
            }
        }
    }

    private func actionGroup(_ actions: [MouseAction], slots: @escaping (Int) -> MouseSlot) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 { Divider().padding(.leading, 12) }
                actionRow(action, slot: slots(index))
            }
        }.background(card)
    }

    private func actionRow(_ action: MouseAction, slot: MouseSlot, direction: MouseDirection? = nil) -> some View {
        Button { editor.edit(slot) } label: {
            HStack(spacing: 8) {
                Image(systemName: direction.map(directionSymbol) ?? action.symbol).frame(width: 22).foregroundStyle(.secondary)
                if let direction { Text(direction.rawValue.capitalized).fontWeight(.medium).frame(width: 48, alignment: .leading) }
                Text(action.title).lineLimit(1)
                Spacer(minLength: 4)
                Text(action.shortcut.label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(.horizontal, 10).frame(height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel((direction.map { $0.rawValue.capitalized + ", " } ?? "") + action.title + ", " + action.shortcut.label)
    }

    private func directionSymbol(_ d: MouseDirection) -> String { "arrow." + d.rawValue }

    @ViewBuilder private var gestures: some View {
        appPicker
        if let appID {
            Toggle("Use custom gestures for " + editor.app.name, isOn: Binding(get: { appGestures }, set: {
                profiles.setAppGestures($0, bundleID: appID, name: editor.app.name)
            })).toggleStyle(.switch)
        }
        Text(appGestures ? editor.app.name + " gestures" : "Universal gestures").font(.headline)
        VStack(spacing: 0) {
            ForEach([MouseDirection.up, .right, .down, .left], id: \.self) { direction in
                if direction != .up { Divider().padding(.leading, 12) }
                let target = appGestures ? appID : nil
                actionRow(config.gesture(direction, for: target), slot: .gesture(direction, bundleID: target, name: editor.app.name), direction: direction)
            }
        }.background(card)
        HStack {
            Label("Gesture distance", systemImage: "arrow.left.and.right").font(.callout)
            Slider(value: Binding(get: { config.gestureThreshold }, set: { profiles.setThreshold($0) }), in: 12...100, step: 2)
                .frame(maxWidth: 220).accessibilityLabel("Gesture distance")
            Text("\(Int(config.gestureThreshold)) pt").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10), lineWidth: 0.8))
    }

    private var actionEditor: some View {
        ZStack {
            Color.black.opacity(0.24).onTapGesture { editor.endEdit() }
            VStack(alignment: .leading, spacing: 14) {
                Text("Edit action").font(.headline)
                TextField("Action name", text: $editor.draft.title).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Keyboard shortcut").font(.callout)
                    Spacer()
                    Button(editor.recording ? "Press a key…" : editor.draft.shortcut.label) { editor.startRecording() }
                        .accessibilityLabel("Record keyboard shortcut")
                }
                if editor.recording { Text("Press the shortcut to record, or Escape to cancel.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel") { editor.endEdit() }.keyboardShortcut(.cancelAction)
                    Button("Save") { editor.save() }.keyboardShortcut(.defaultAction)
                        .disabled(editor.recording || editor.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 330).background(.thickMaterial, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.15)))
                .shadow(radius: 12)
        }
    }
}
