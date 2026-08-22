import SwiftUI
import AppKit
import ClapCore

// MARK: - Persistence & component health for SettingsView

extension SettingsView {

    func save(_ key: String, _ value: String) {
        guard loaded else { return }
        enqueueSave(key: key, value: value)
    }

    func saveMegabytes(_ key: String, megabytes: Int) {
        guard loaded else { return }
        let clamped = max(1, megabytes)
        let bytes = ByteSize.parse("\(clamped)MB") ?? Int64(clamped) * 1_048_576
        enqueueSave(key: key, value: String(bytes))
    }

    /// Chains writes per config key: each task waits for its predecessor so a
    /// burst of rapid changes lands strictly in the order they were made.
    /// SettingsView is a struct, so the task captures a value copy; @State
    /// writes still reach SwiftUI's external storage.
    private func enqueueSave(key: String, value: String) {
        let previous = saveTasks[key]
        saveTasks[key] = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await self.store.setConfig(key, value: value)
                IPC.post(.configChanged)
            } catch {
                self.reportSaveFailure(key)
            }
        }
    }

    /// A failed settings write leaves the UI and the store disagreeing;
    /// surface it instead of silently dropping it.
    private func reportSaveFailure(_ key: String) {
        saveError = String(localized: "Couldn't save \(key). Check disk space/permissions and reopen Settings.")
        Task {
            try? await Task.sleep(nanoseconds: Timing.saveErrorResetNanos)
            saveError = nil
        }
    }

    // MARK: - Component health

    private func refreshHealth() {
        guard let health = healthProvider?() else { return }
        hotKeyOK = health.hotKeyOK
        snippetTapOK = health.snippetTapOK
    }

    var healthSection: some View {
        Section("Health") {
            HStack {
                Label {
                    Text("Global hotkey")
                    if !hotKeyOK {
                        Text("— registration failed; another app may own this shortcut")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: hotKeyOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(hotKeyOK ? Color.green : Color.orange)
                }
                Spacer()
            }
            HStack {
                Label {
                    Text("Snippet listener")
                    if !snippetTapOK {
                        Text("— needs Accessibility permission; expansion is off")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                } icon: {
                    Image(systemName: snippetTapOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(snippetTapOK ? Color.green : Color.orange)
                }
                Spacer()
            }
        }
    }
}
