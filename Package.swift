// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clap",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Core engine: database, search, dedup, eviction, settings, image store.
        // No UI. Shared by the app and the CLI.
        .target(
            name: "ClapCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Background app: pasteboard monitor, global hotkey, SwiftUI panel, menu bar.
        .executableTarget(
            name: "ClapApp",
            dependencies: ["ClapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line interface. The binary is named `clap`.
        .executableTarget(
            name: "clap",
            dependencies: ["ClapCore"],
            path: "Sources/ClapCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClapCoreTests",
            dependencies: ["ClapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
