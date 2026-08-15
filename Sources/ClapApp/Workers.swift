import Foundation
import ClapCore

/// Background maintenance: limits/retention every 5 minutes (and at launch),
/// vacuum every hour, one-time thumbnail warmup for the newest 50 images.
/// Everything runs in detached low-priority tasks, never on the main actor.
final class MaintenanceWorkers {

    private var tasks: [Task<Void, Never>] = []

    func start(store: ClipboardStore) {
        guard tasks.isEmpty else { return }

        // One-time thumbnail warmup (failures ignored).
        tasks.append(Task.detached(priority: .background) {
            if let images = try? await store.list(type: .image, limit: 50, offset: 0) {
                for entry in images {
                    if Task.isCancelled { return }
                    _ = try? await store.thumbnailURL(for: entry)
                }
            }
        })

        // Limits + retention: immediately, then every 5 minutes.
        tasks.append(Task.detached(priority: .background) {
            while !Task.isCancelled {
                let evicted = (try? await store.enforceLimits()) ?? 0
                let expired = (try? await store.applyRetention()) ?? 0
                if evicted + expired > 0 {
                    IPC.post(.storeChanged)
                }
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        })

        // Vacuum: every hour.
        tasks.append(Task.detached(priority: .background) {
            while !Task.isCancelled {
                try? await store.vacuumIfNeeded()
                try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
