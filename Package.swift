// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowManager",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindowManagerApp", targets: ["WindowManagerApp"]),
        .library(name: "WindowManagerCore", targets: ["WindowManagerCore"]),
    ],
    targets: [
        // Everything that talks to the system or holds logic. No UI, so it stays testable and reusable
        // by later phases (snapping, layouts, displays/Spaces, save/restore, tiling).
        .target(
            name: "WindowManagerCore",
            path: "Sources/WindowManagerCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        // The menu bar app: status item, onboarding, settings UI.
        .executableTarget(
            // Not named "WindowManager": macOS already runs a system process with that name
            // (Stage Manager), and `pkill -x WindowManager` would kill it.
            name: "WindowManagerApp",
            dependencies: ["WindowManagerCore"],
            path: "Sources/WindowManagerApp",
            linkerSettings: [
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "WindowManagerCoreTests",
            dependencies: ["WindowManagerCore"],
            path: "Tests/WindowManagerCoreTests"
        ),
    ]
)
