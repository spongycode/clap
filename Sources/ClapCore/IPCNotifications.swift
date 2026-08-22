import Foundation

public enum ClapIdentity {
    public static let bundleID = "com.spongycode.clap"
}

/// DistributedNotificationCenter names for app <-> CLI IPC.
/// Contract: ARCHITECTURE.md "IPC" section.
public enum IPCNotifications {
    public static let openUI = "com.spongycode.clap.openUI"
    public static let storeChanged = "com.spongycode.clap.storeChanged"
    public static let configChanged = "com.spongycode.clap.configChanged"
}
