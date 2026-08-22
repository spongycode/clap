import Foundation
import ClapCore
import os

/// Background maintenance: limits/retention every 5 minutes (and at launch),
/// vacuum every hour, one-time thumbnail warmup for the newest 50 images.
/// Everything runs in detached low-priority tasks, never on the main actor.
final class MaintenanceWorkers {

    private static let logger = Logger(subsystem: ClapIdentity.bundleID, category: "workers")
    private static let limitsIntervalNanos: UInt64 = 300 * 1_000_000_000
    private static let vacuumIntervalNanos: UInt64 = 3_600 * 1_000_000_000

    private var tasks: [Task<Void, Never>] = []

    func start(store: ClipboardStore) {
        guard tasks.isEmpty else { return }

        // One-time thumbnail warmup (failures logged, non-fatal).
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
                do {
                    let evicted = try await store.enforceLimits()
                    let expired = try await store.applyRetention()
                    if evicted + expired > 0 {
                        IPC.post(.storeChanged)
                    }
                } catch {
                    Self.logger.error("maintenance pass failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: Self.limitsIntervalNanos)
            }
        })

        // Vacuum: every hour.
        tasks.append(Task.detached(priority: .background) {
            while !Task.isCancelled {
                do {
                    try await store.vacuumIfNeeded()
                } catch {
                    Self.logger.error("vacuum failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: Self.vacuumIntervalNanos)
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
