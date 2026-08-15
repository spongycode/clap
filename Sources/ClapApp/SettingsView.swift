import SwiftUI
import AppKit
import ServiceManagement
import ClapCore

/// Owns the standard titled Settings window (opened from the gear button and
/// the menu bar item).
@MainActor
final class SettingsWindowController: NSObject {

    private let store: ClipboardStore
    private var window: NSWindow?

    init(store: ClipboardStore) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "clap Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let store: ClipboardStore

    @State private var loaded = false
    @State private var textMaxEntries = 100_000
    @State private var textMaxMB = 50
    @State private var imageMaxEntries = 500
    @State private var imageMaxMB = 100
    @State private var shellEnabled = true
    @State private var shellMaxEntries = 50_000
    @State private var shellMaxMB = 10
    @State private var shellHistfile = ""
    @State private var retentionDays = 0
    @State private var launchAtLogin = false
    @State private var suppressLoginToggle = false
    @State private var launchError: String?
    @State private var paused = false
    @State private var pasteOnCopy = true
    @State private var exclusions: [String] = []
    @State private var newExclusion = ""

    var body: some View {
        formWithLimitHandlers
            .onChange(of: shellEnabled) { _, value in save("shell.enabled", value ? "1" : "0") }
            .onChange(of: shellHistfile) { _, value in save("shell.histfile", value.trimmingCharacters(in: .whitespaces)) }
            .onChange(of: retentionDays) { _, value in save("retention.days", String(value)) }
            .onChange(of: paused) { _, value in save("monitoring.paused", value ? "1" : "0") }
            .onChange(of: pasteOnCopy) { _, value in
                save("paste.on_copy", value ? "1" : "0")
                if value && !Paster.isTrusted {
                    Paster.promptAccessibility()
                }
            }
            .onChange(of: launchAtLogin) { _, value in updateLaunchAtLogin(value) }
            .formStyle(.grouped)
            .frame(width: 480, height: 620)
            .task { await load() }
    }

    private var formWithLimitHandlers: some View {
        settingsForm
            .onChange(of: textMaxEntries) { _, value in save("text.max_entries", String(max(1, value))) }
            .onChange(of: textMaxMB) { _, value in saveMegabytes("text.max_size", megabytes: value) }
            .onChange(of: imageMaxEntries) { _, value in save("image.max_entries", String(max(1, value))) }
            .onChange(of: imageMaxMB) { _, value in saveMegabytes("image.max_size", megabytes: value) }
            .onChange(of: shellMaxEntries) { _, value in save("shell.max_entries", String(max(1, value))) }
            .onChange(of: shellMaxMB) { _, value in saveMegabytes("shell.max_size", megabytes: value) }
    }

    private static let intFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        return formatter
    }()

    private var settingsForm: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let appIcon = NSImage(contentsOfFile: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/AppIcon.png").path) ?? NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clap")
                            .font(.title2.weight(.bold))
                        Text("Local-first clipboard & shell history manager · v1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Text limits") {
                limitRow(title: "Max entries", value: $textMaxEntries)
                sizeRow(title: "Max total size", megabytes: $textMaxMB)
            }
            Section("Image limits") {
                limitRow(title: "Max entries", value: $imageMaxEntries)
                sizeRow(title: "Max total size", megabytes: $imageMaxMB)
            }
            Section("Shell history") {
                Toggle("Capture shell history", isOn: $shellEnabled)
                if shellEnabled {
                    limitRow(title: "Max entries", value: $shellMaxEntries)
                    sizeRow(title: "Max total size", megabytes: $shellMaxMB)
                    HStack {
                        Text("History file")
                        Spacer()
                        TextField("Auto-detect (~/.zsh_history)", text: $shellHistfile)
                            .frame(width: 220)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Section("Retention") { retentionPicker }
            Section("General") { generalSection }
            Section("Excluded apps") { exclusionsSection }
        }
    }

    private var retentionPicker: some View {
        Picker("Delete unpinned items after", selection: $retentionDays) {
            Text("Never").tag(0)
            Text("7 days").tag(7)
            Text("30 days").tag(30)
            Text("90 days").tag(90)
            Text("1 year").tag(365)
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Toggle("Launch at login", isOn: $launchAtLogin)
        if let launchError {
            Text(launchError)
                .font(.caption)
                .foregroundColor(.red)
        }
        Toggle("Pause monitoring", isOn: $paused)
        Toggle("Paste automatically on select", isOn: $pasteOnCopy)
        if pasteOnCopy {
            HStack {
                if Paster.isTrusted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Accessibility permission granted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Accessibility permission needed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant Access") {
                        Paster.promptAccessibility()
                        Paster.openAccessibilitySettings()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var exclusionsSection: some View {
        if exclusions.isEmpty {
            Text("Clipboard changes from excluded apps are never captured.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(exclusions, id: \.self) { bundleID in
            exclusionRow(bundleID)
        }
        addExclusionRow
    }

    private func exclusionRow(_ bundleID: String) -> some View {
        HStack {
            Text(bundleID)
            Spacer()
            Button {
                removeExclusion(bundleID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var addExclusionRow: some View {
        HStack {
            TextField("Bundle identifier (com.example.app)", text: $newExclusion)
                .onSubmit(addTypedExclusion)
            Button("Add", action: addTypedExclusion)
                .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
            Menu {
                ForEach(runningApps(), id: \.processIdentifier) { app in
                    Button(menuTitle(for: app)) {
                        if let id = app.bundleIdentifier { addExclusion(id) }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .fixedSize()
            .help("Add a currently running app")
        }
    }

    // MARK: - Rows

    private func limitRow(title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, formatter: Self.intFormatter)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: 1...1_000_000, step: 100)
                .labelsHidden()
        }
    }

    private func sizeRow(title: String, megabytes: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: megabytes, formatter: Self.intFormatter)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text("MB")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Load / save

    private func load() async {
        guard !loaded else { return }
        textMaxEntries = await configInt("text.max_entries", fallback: 100_000)
        textMaxMB = await configBytesAsMB("text.max_size", fallback: 50)
        imageMaxEntries = await configInt("image.max_entries", fallback: 500)
        imageMaxMB = await configBytesAsMB("image.max_size", fallback: 100)
        shellEnabled = await configString("shell.enabled") != "0"
        shellMaxEntries = await configInt("shell.max_entries", fallback: 50_000)
        shellMaxMB = await configBytesAsMB("shell.max_size", fallback: 10)
        shellHistfile = (await configString("shell.histfile")) ?? ""
        retentionDays = await configInt("retention.days", fallback: 0)
        paused = await configString("monitoring.paused") == "1"
        pasteOnCopy = await configString("paste.on_copy") != "0"
        launchAtLogin = await configString("launch_at_login") == "1"
        if let raw = await configString("exclusions"),
           let data = raw.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            exclusions = array
        }
        loaded = true
    }

    private func configString(_ key: String) async -> String? {
        (try? await store.config(key)) ?? nil
    }

    private func configInt(_ key: String, fallback: Int) async -> Int {
        if let raw = await configString(key), let value = Int(raw) { return value }
        return fallback
    }

    private func configBytesAsMB(_ key: String, fallback: Int) async -> Int {
        if let raw = await configString(key), let bytes = Int64(raw) {
            return max(1, Int(bytes / 1_048_576))
        }
        return fallback
    }

    private func save(_ key: String, _ value: String) {
        guard loaded else { return }
        Task {
            try? await store.setConfig(key, value: value)
            IPC.post(.configChanged)
        }
    }

    private func saveMegabytes(_ key: String, megabytes: Int) {
        guard loaded else { return }
        let clamped = max(1, megabytes)
        let bytes = ByteSize.parse("\(clamped)MB") ?? Int64(clamped) * 1_048_576
        Task {
            try? await store.setConfig(key, value: String(bytes))
            IPC.post(.configChanged)
        }
    }

    // MARK: - Launch at login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard loaded, !suppressLoginToggle else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
            save("launch_at_login", enabled ? "1" : "0")
        } catch {
            // Typical in dev/unbundled builds where SMAppService is unavailable.
            launchError = "Launch at login is unavailable: \(error.localizedDescription)"
            suppressLoginToggle = true
            launchAtLogin = !enabled
            Task { suppressLoginToggle = false }
        }
    }

    // MARK: - Exclusions

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func menuTitle(for app: NSRunningApplication) -> String {
        let name = app.localizedName ?? "?"
        let bundleID = app.bundleIdentifier ?? ""
        return "\(name) — \(bundleID)"
    }

    private func addTypedExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        newExclusion = ""
        addExclusion(trimmed)
    }

    private func addExclusion(_ bundleID: String) {
        guard !bundleID.isEmpty, !exclusions.contains(bundleID) else { return }
        exclusions.append(bundleID)
        saveExclusions()
    }

    private func removeExclusion(_ bundleID: String) {
        exclusions.removeAll { $0 == bundleID }
        saveExclusions()
    }

    private func saveExclusions() {
        guard let data = try? JSONEncoder().encode(exclusions),
              let json = String(data: data, encoding: .utf8) else { return }
        save("exclusions", json)
    }
}
