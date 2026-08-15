import Foundation

/// DistributedNotificationCenter names shared between the app and the CLI
/// (see ARCHITECTURE.md "IPC").
enum IPC {
    enum Name: String {
        case openUI = "com.spongycode.clap.openUI"
        case storeChanged = "com.spongycode.clap.storeChanged"
        case configChanged = "com.spongycode.clap.configChanged"

        var notification: Notification.Name { Notification.Name(rawValue) }
    }

    static func post(_ name: Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name.notification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// Observes a distributed notification and delivers it on the main actor.
    @discardableResult
    static func observe(_ name: Name, _ handler: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name.notification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
    }
}
