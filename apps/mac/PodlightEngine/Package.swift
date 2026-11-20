// swift-tools-version: 6.2
import PackageDescription

// The rules Podlight runs by, without any interface: scheduling, limits, and later the RunPod
// client and the local gateway. Kept free of AppKit/SwiftUI so it builds and tests with plain
// `swift test`, and so the same rules can be checked against `spec/` on every change.
let package = Package(
    name: "PodlightEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PodlightEngine", targets: ["PodlightEngine"]),
    ],
    targets: [
        .target(name: "PodlightEngine"),
        .testTarget(name: "PodlightEngineTests", dependencies: ["PodlightEngine"]),
    ]
)
