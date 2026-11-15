// swift-tools-version: 6.2
// Only for `make test`: the app itself is built by scripts/build.sh. TidemarkCore is the app's pure logic and its
// providers (Sources/Core, Sources/Providers), compiled into the app directly and tested here on their own.
import PackageDescription

let package = Package(
    name: "Tidemark",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "TidemarkCore", path: "Sources", exclude: ["App"], sources: ["Core", "Providers"]),
        .testTarget(name: "TidemarkTests", dependencies: ["TidemarkCore"], path: "Tests/TidemarkTests"),
    ]
)
