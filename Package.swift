// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode is staged, not abandoned: the whole codebase is clean
// under full v6 checking, but Command Line Tools Swift 6.3.3.1 crashes in IRGen
// (SmallVector 2^32+1, module-cumulative — evidence in
// .agents/missions/2026-10-10-engine-upgrade/journal.md) before it can emit the
// module. Flip both targets to .swiftLanguageMode(.v6) and drop the
// StrictConcurrency line once a toolchain without that bug builds this package.
let concurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "Kestrel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kestrel", path: "Sources", swiftSettings: concurrencySettings),
        .testTarget(name: "KestrelTests", dependencies: ["Kestrel"], path: "Tests",
                    swiftSettings: concurrencySettings),
    ]
)
