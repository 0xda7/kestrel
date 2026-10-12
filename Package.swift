// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode, LIVE since 2026-10-12: the IRGen SmallVector crash
// (module-cumulative, reproduced 2026-10-10 on CLT 6.3.3.1 and CI Xcode 26
// run 38093069969) is gone under Xcode 26.5 — the whole package builds in
// v6 mode, the check suite runs green, and the release product builds clean
// (swift build -c release --product Kestrel). History and the bisect live in
// .agents/missions/2026-10-10-engine-upgrade/journal.md; the flip's
// verification is in .agents/missions/2026-10-12-enterprise-upgrade/.
let concurrencySettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "Kestrel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KestrelCore", path: "Sources", exclude: ["Main"],
                swiftSettings: concurrencySettings
                // kestrel-checks @testable-imports this module; SwiftPM only
                // passes -enable-testing to test targets, so grant it here
                // for debug builds (release artifacts are unaffected).
                + [.unsafeFlags(["-enable-testing"], .when(configuration: .debug))]),
        .executableTarget(name: "Kestrel", dependencies: ["KestrelCore"], path: "Sources/Main"),
        // Same staged language settings as the app target: the harness is
        // v5-minimal by design (its shims predate v6 checking), and the
        // registry statics are only touched from the runner.
        .executableTarget(name: "kestrel-checks", dependencies: ["KestrelCore"], path: "Tests",
                          swiftSettings: concurrencySettings),
    ]
)
