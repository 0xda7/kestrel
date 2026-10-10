// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode is staged, not abandoned: the whole codebase is clean
// under full v6 checking, but the Swift 6.3.x toolchain crashes in IRGen
// (SmallVector 2^32+1, module-cumulative) before it can emit this package.
// Reproduced in BOTH environments on 2026-10-10 under v6 mode:
//   - local Command Line Tools 6.3.3.1 (IRGen for SettingsTab.swift)
//   - CI Xcode 26 on macos-26 (IRGen for DashboardTab.swift, run 38093069969)
// so it is a toolchain bug, not local. Evidence and the all-stubs bisect live
// in .agents/missions/2026-10-10-engine-upgrade/journal.md. Flip both targets
// to .swiftLanguageMode(.v6) once a fixed toolchain builds this package.
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
