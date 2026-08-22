import AppKit
import SwiftUI

/// Caches and resolves native macOS application icons from bundle identifiers.
public enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    public static func icon(forBundleID bundleID: String, size: CGFloat = 16) -> NSImage? {
        let key = "\(bundleID)-\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

/// SwiftUI view that renders the application icon for a bundle identifier.
public struct AppIconView: View {
    let bundleID: String
    var size: CGFloat

    public init(bundleID: String, size: CGFloat = 14) {
        self.bundleID = bundleID
        self.size = size
    }

    public var body: some View {
        if let icon = AppIconCache.icon(forBundleID: bundleID, size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
