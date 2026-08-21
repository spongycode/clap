// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clap",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Core engine: database, search, dedup, eviction, settings, image store,
        // text analysis. No UI. Shared by the app and the CLI.
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
        // CLI command logic as a library so it is unit-testable; the executable
        // target below stays a thin entry point.
        .target(
            name: "ClapCLIKit",
            dependencies: ["ClapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command-line interface. The binary is named `clap`.
        .executableTarget(
            name: "clap",
            dependencies: ["ClapCLIKit"],
            path: "Sources/ClapCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClapCoreTests",
            dependencies: ["ClapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClapCLITests",
            dependencies: ["ClapCLIKit"],
            path: "Tests/ClapCLITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClapAppTests",
            dependencies: ["ClapApp"],
            path: "Tests/ClapAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
