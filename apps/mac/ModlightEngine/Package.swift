// swift-tools-version: 6.2
import PackageDescription

// The rules Modlight runs by, without any interface: scheduling, limits, the RunPod and Hugging
// Face clients, the pod lifecycle and the local OpenAI-compatible gateway. Kept free of
// AppKit/SwiftUI so it builds and tests with plain `swift test`, and so the same rules can be
// checked against `spec/` on every change.
let package = Package(
    name: "ModlightEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ModlightEngine", targets: ["ModlightEngine"]),
    ],
    dependencies: [
        // HTTP server for the local gateway (SwiftNIO underneath).
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
    ],
    targets: [
        .target(
            name: "ModlightEngine",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")],
            resources: [.copy("Resources/gpus.json"), .copy("Resources/boot.sh"), .copy("Resources/watchdog.py")]
        ),
        .testTarget(name: "ModlightEngineTests", dependencies: ["ModlightEngine"]),
    ]
)
