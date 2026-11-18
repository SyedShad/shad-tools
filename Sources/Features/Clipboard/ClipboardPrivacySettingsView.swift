import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardPrivacySettingsView: View {
    @ObservedObject var browser: HistoryBrowser

    var body: some View {
        Form {
            Section("History") {
                Picker("Keep unpinned copies for", selection: Binding(get: { browser.privacy.retention }, set: chooseRetention)) {
                    ForEach(ClipboardRetention.allCases, id: \.self) { period in
                        Text(period.title).tag(period)
                    }
                }
                Text("Age is measured from the last copy. Pinned entries and saved snippets are kept. The 200-entry and 100 MiB history limits still apply.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Excluded applications") {
                ForEach(browser.privacy.excludedApps) { app in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { browser.tool?.removeExclusion(app.id) } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).accessibilityLabel("Remove " + app.name + " from exclusions")
                    }
                }
                Button("Add Applications…", action: selectApplications)
                Text("Future copies from these apps are skipped. Previously saved items can be deleted from history. Known password managers and concealed copies are already filtered.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let issue = browser.privacyPickerError ?? browser.issue {
                    Text(issue).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 380)
        .alert("Shorten clipboard history?", isPresented: Binding(get: { browser.pendingRetention != nil }, set: {
            if !$0 { browser.pendingRetention = nil }
        }), presenting: browser.pendingRetention) { period in
            Button("Keep " + period.title, role: .destructive) { browser.tool?.setRetention(period) }
            Button("Cancel", role: .cancel) {}
        } message: { period in
            Text("Unpinned copies older than " + period.title + " will be deleted now. Pinned entries and saved snippets are kept.")
        }
    }

    private func chooseRetention(_ period: ClipboardRetention) {
        let current = browser.privacy.retention
        guard current != period else { return }
        if period != .noAgeLimit && (current == .noAgeLimit || period.rawValue < current.rawValue) {
            browser.pendingRetention = period
        } else {
            browser.tool?.setRetention(period)
        }
    }

    private func selectApplications() {
        let panel = NSOpenPanel()
        panel.title = "Exclude Applications from Clipboard History"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK else { return }
            let apps = panel.urls.compactMap { url -> ClipboardExcludedApp? in
                guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
                return ClipboardExcludedApp(id: id, name: url.deletingPathExtension().lastPathComponent)
            }
            browser.privacyPickerError = apps.count == panel.urls.count ? nil : "Some selected apps had no bundle identifier."
            if !apps.isEmpty { browser.tool?.excludeApplications(apps) }
        }
    }
}
