// swift-tools-version:5.9
//
// SPM manifest for the TEST HARNESS ONLY (`swift test`).
//
// The app itself is deliberately NOT built with SPM — build.sh compiles
// Sources/*.swift directly with swiftc (universal binary). This package
// exposes just the pure-logic Core_*.swift files (Foundation-only, no
// AppKit/SwiftUI, no Process/file I/O) as a library so unit tests can run
// against them. `sources:` is an explicit allowlist — app files must never
// enter the package.
import PackageDescription

let package = Package(
    name: "CCCostCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CCCostCore",
            path: "Sources",
            sources: [
                "Core_Models.swift",
                "Core_ModelClass.swift",
                "Core_UsageParser.swift",
                "Core_DateLogic.swift",
                "Core_KeychainCodec.swift",
            ]
        ),
        .testTarget(
            name: "CCCostCoreTests",
            dependencies: ["CCCostCore"],
            path: "Tests/CCCostCoreTests"
        ),
    ]
)
