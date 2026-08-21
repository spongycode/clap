import SwiftUI
import AppKit
import ServiceManagement
import ClapCore

/// Owns the standard titled Settings window (opened from the gear button and
/// the menu bar item).
@MainActor
final class SettingsWindowController: UtilityWindowController {

    private let store: ClipboardStore
    var healthProvider: (() -> (hotKeyOK: Bool, snippetTapOK: Bool))?

    init(store: ClipboardStore) {
        self.store = store
        super.init(title: "clap Settings",
                   contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                   styleMask: [.titled, .closable, .miniaturizable])
    }

    func show() {
        show(rootView: SettingsView(store: store, healthProvider: healthProvider))
    }
}

struct SettingsView: View {
    let store: ClipboardStore
    /// Supplies live component health when the window opens. Set by the app
    /// delegate; nil in previews.
    var healthProvider: (() -> (hotKeyOK: Bool, snippetTapOK: Bool))?

    @State var loaded = false
    @State private var stats: StoreStats?
    @State private var textMaxEntries = 100_000
    @State private var textMaxMB = 50
    @State private var imageMaxEntries = 500
    @State private var imageMaxMB = 100
    @State private var shellEnabled = true
    @State private var shellMaxEntries = 50_000
    @State private var shellMaxMB = 10
    @State private var shellHistfile = ""
    @State private var retentionDays = 0
    @State private var hotkey = "cmd+shift+v"
    @State private var launchAtLogin = false
    /// Serializes settings writes per key: rapid stepper/toggle changes each
    /// await the previous task for that key, so the store always converges to
    /// the newest value regardless of actor scheduling order.
    @State var saveTasks: [String: Task<Void, Never>] = [:]
    @State private var suppressLoginToggle = false
    @State private var launchError: String?
    @State var saveError: String?
    @State var hotKeyOK = true
    @State var snippetTapOK = true
    @State private var paused = false
    @State private var pasteOnCopy = true
    @State private var snippetsEnabled = true
    @State private var exclusions: [String] = []
    @State private var newExclusion = ""

    var body: some View {
        formWithLimitHandlers
            .onChange(of: shellEnabled) { _, value in save(ConfigKey.shellEnabled, value ? "1" : "0") }
            .onChange(of: shellHistfile) { _, value in save(ConfigKey.shellHistfile, value.trimmingCharacters(in: .whitespaces)) }
            .onChange(of: retentionDays) { _, value in save(ConfigKey.retentionDays, String(value)) }
            .onChange(of: hotkey) { _, value in save(ConfigKey.uiHotkey, value) }
            .onChange(of: paused) { _, value in save(ConfigKey.monitoringPaused, value ? "1" : "0") }
            .onChange(of: snippetsEnabled) { _, value in
                save(ConfigKey.snippetsEnabled, value ? "1" : "0")
                SnippetExpander.shared.setEnabled(value)
            }
            .onChange(of: pasteOnCopy) { _, value in
                save(ConfigKey.pasteOnCopy, value ? "1" : "0")
                if value && !Paster.isTrusted {
                    Paster.promptAccessibility()
                }
            }
            .onChange(of: launchAtLogin) { _, value in updateLaunchAtLogin(value) }
            .formStyle(.grouped)
            .frame(width: 500, height: 640)
            .task {
                await load()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: IPC.Name.storeChanged.notification)) { _ in
                Task { await refreshStats() }
            }
    }

    private var formWithLimitHandlers: some View {
        settingsForm
            .onChange(of: textMaxEntries) { _, value in save(ConfigKey.textMaxEntries, String(max(1, value))) }
            .onChange(of: textMaxMB) { _, value in saveMegabytes(ConfigKey.textMaxSize, megabytes: value) }
            .onChange(of: imageMaxEntries) { _, value in save(ConfigKey.imageMaxEntries, String(max(1, value))) }
            .onChange(of: imageMaxMB) { _, value in saveMegabytes(ConfigKey.imageMaxSize, megabytes: value) }
            .onChange(of: shellMaxEntries) { _, value in save(ConfigKey.shellMaxEntries, String(max(1, value))) }
            .onChange(of: shellMaxMB) { _, value in saveMegabytes(ConfigKey.shellMaxSize, megabytes: value) }
    }

    private var settingsForm: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    let iconPath = Bundle.main.bundleURL
                        .appendingPathComponent("Contents/Resources/AppIcon.png").path
                    if let appIcon = NSImage(contentsOfFile: iconPath) ?? NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clap")
                            .font(.title2.weight(.bold))
                        Text("Local-first clipboard & shell history manager · v0.2.0")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            healthSection

            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("Text limits") {
                NumericInputRow(
                    title: "Max entries",
                    pill: formatCount(stats?.textCount),
                    pillRatio: stats.map { Double($0.textCount) / Double(max(1, textMaxEntries)) },
                    value: $textMaxEntries,
                    range: 1...1_000_000,
                    step: 1_000
                )
                NumericInputRow(
                    title: "Max total size",
                    pill: formatBytes(stats?.textBytes),
                    pillRatio: stats.map { Double($0.textBytes) / Double(max(1, Int64(textMaxMB) * 1024 * 1024)) },
                    value: $textMaxMB,
                    range: 1...50_000,
                    step: 10,
                    suffix: "MB"
                )
            }

            Section("Image limits") {
                NumericInputRow(
                    title: "Max entries",
                    pill: formatCount(stats?.imageCount),
                    pillRatio: stats.map { Double($0.imageCount) / Double(max(1, imageMaxEntries)) },
                    value: $imageMaxEntries,
                    range: 1...10_000,
                    step: 50
                )
                NumericInputRow(
                    title: "Max total size",
                    pill: formatBytes(stats?.imageBytes),
                    pillRatio: stats.map { Double($0.imageBytes) / Double(max(1, Int64(imageMaxMB) * 1024 * 1024)) },
                    value: $imageMaxMB,
                    range: 1...50_000,
                    step: 20,
                    suffix: "MB"
                )
            }

            Section("Shell history") {
                Toggle("Capture shell history", isOn: $shellEnabled)
                if shellEnabled {
                    NumericInputRow(
                        title: "Max entries",
                        pill: formatCount(stats?.shellCount),
                        pillRatio: stats.map { Double($0.shellCount) / Double(max(1, shellMaxEntries)) },
                        value: $shellMaxEntries,
                        range: 1...500_000,
                        step: 1_000
                    )
                    NumericInputRow(
                        title: "Max total size",
                        pill: formatBytes(stats?.shellBytes),
                        pillRatio: stats.map { Double($0.shellBytes) / Double(max(1, Int64(shellMaxMB) * 1024 * 1024)) },
                        value: $shellMaxMB,
                        range: 1...10_000,
                        step: 5,
                        suffix: "MB"
                    )
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

    private func formatCount(_ count: Int?) -> String {
        let val = count ?? 0
        return "\(NumberFormatter.localizedString(from: NSNumber(value: val), number: .decimal)) current"
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        let val = bytes ?? 0
        return "\(ByteSize.format(val)) current"
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
        Picker("Global shortcut", selection: $hotkey) {
            ForEach(HotKeyDefinition.presets) { preset in
                Text(preset.title).tag(preset.id)
            }
        }
        Toggle("Launch at login", isOn: $launchAtLogin)
        if let launchError {
            Text(launchError)
                .font(.caption)
                .foregroundColor(.red)
        }
        Toggle("Pause monitoring", isOn: $paused)
        Toggle("Enable snippet expansion (Text Expander)", isOn: $snippetsEnabled)
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

    // MARK: - Load / save

    private func load() async {
        guard !loaded else { return }
        textMaxEntries = await configInt(ConfigKey.textMaxEntries, fallback: 100_000)
        textMaxMB = await configBytesAsMB(ConfigKey.textMaxSize, fallback: 50)
        imageMaxEntries = await configInt(ConfigKey.imageMaxEntries, fallback: 500)
        imageMaxMB = await configBytesAsMB(ConfigKey.imageMaxSize, fallback: 100)
        shellEnabled = await configString(ConfigKey.shellEnabled) != "0"
        shellMaxEntries = await configInt(ConfigKey.shellMaxEntries, fallback: 50_000)
        shellMaxMB = await configBytesAsMB(ConfigKey.shellMaxSize, fallback: 10)
        shellHistfile = (await configString(ConfigKey.shellHistfile)) ?? ""
        retentionDays = await configInt(ConfigKey.retentionDays, fallback: 0)
        hotkey = (await configString(ConfigKey.uiHotkey)) ?? HotKeyDefinition.defaultID
        paused = await configString(ConfigKey.monitoringPaused) == "1"
        snippetsEnabled = await configString(ConfigKey.snippetsEnabled) != "0"
        pasteOnCopy = await configString(ConfigKey.pasteOnCopy) != "0"
        launchAtLogin = await configString(ConfigKey.launchAtLogin) == "1"
        if let raw = await configString(ConfigKey.exclusions),
           let data = raw.data(using: .utf8),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            exclusions = array
        }
        await refreshStats()
        loaded = true
    }

    private func refreshStats() async {
        stats = try? await store.stats()
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
            save(ConfigKey.launchAtLogin, enabled ? "1" : "0")
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
        save(ConfigKey.exclusions, json)
    }
}

// MARK: - Strictly Bounded & Fixed-Height Numeric Input Row

private struct NumericInputRow: View {
    let title: String
    var pill: String?
    var pillRatio: Double?
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var suffix: String?

    @State private var text: String = ""

    private var pillColors: (foreground: Color, background: Color) {
        guard let ratio = pillRatio else {
            return (.secondary, Color.primary.opacity(0.07))
        }
        if ratio >= 0.90 {
            return (.red, Color.red.opacity(0.18))
        } else if ratio >= 0.70 {
            return (.orange, Color.orange.opacity(0.16))
        } else {
            return (.green, Color.green.opacity(0.15))
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)

            if let pill {
                let colors = pillColors
                Text(pill)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(colors.foreground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colors.background)
                    )
            }

            Spacer(minLength: 12)

            TextField("", text: $text)
                .frame(width: 80, height: 22)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .onChange(of: text) { _, newText in
                    let digits = newText.filter { $0.isNumber }
                    if let parsed = Int(digits) {
                        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
                        value = clamped
                        if digits != newText || parsed != clamped {
                            text = String(clamped)
                        }
                    } else if digits.isEmpty {
                        // User cleared text to re-type
                    } else {
                        text = String(value)
                    }
                }
                .onSubmit {
                    commitText()
                }

            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
                    .frame(width: 25, alignment: .leading)
            }

            Stepper("", value: Binding(
                get: { value },
                set: {
                    let clamped = min(max($0, range.lowerBound), range.upperBound)
                    value = clamped
                    text = String(clamped)
                }
            ), in: range, step: step)
            .labelsHidden()
        }
        .frame(minHeight: 26)
        .onAppear {
            text = String(value)
        }
        .onChange(of: value) { _, newValue in
            if text != String(newValue) {
                text = String(newValue)
            }
        }
    }

    private func commitText() {
        let digits = text.filter { $0.isNumber }
        if let parsed = Int(digits) {
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = clamped
            text = String(clamped)
        } else {
            text = String(value)
        }
    }
}
