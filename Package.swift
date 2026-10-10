// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode: the whole codebase is clean under full v6 checking.
// History: CLT Swift 6.3.3.1 crashed in IRGen (SmallVector 2^32+1,
// module-cumulative — evidence in
// .agents/missions/2026-10-10-engine-upgrade/journal.md), so the mode was
// staged to v5 + StrictConcurrency. CI's Xcode 26 toolchain built the package
// cleanly, so the mode is flipped to v6 here; if a CI run reproduces the
// IRGen crash, revert this file to the staged form.
let concurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
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
