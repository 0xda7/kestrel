// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Kestrel

/// KES-01/KES-03/KES-04 regression tests: the engine key must never appear in
/// argv, logs, or diagnostics, and a keyless LAN bind must be refused.
final class SecretRedactionTests: XCTestCase {
    private func makeSettings(apiKeyEnabled: Bool = false) -> ServerSettings {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                               ngl: 99, ncmoe: 24, ctx: 16384, threads: 6, flashAttn: "auto",
                               noMmap: true, jinja: true,
                               vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                               cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
        s.apiKeyEnabled = apiKeyEnabled
        return s
    }

    private func makeHardware() -> HardwareInfo {
        HardwareInfo(cpuBrand: "Test CPU", physicalCores: 8, logicalCores: 16, ramGB: 32,
                     arch: "x86_64", model: "Test Mac", osVersion: "macOS 26", gpus: [])
    }

    func testRedactArgumentsMasksEveryAPIKey() {
        let args = ["-m", "/tmp/m.gguf", "--api-key", "SECRET-ONE", "--port", "8080",
                    "--api-key", "SECRET-TWO"]
        let redacted = ServerController.redactArguments(args).joined(separator: " ")
        XCTAssertFalse(redacted.contains("SECRET-ONE"))
        XCTAssertFalse(redacted.contains("SECRET-TWO"))
        XCTAssertEqual(redacted.components(separatedBy: "***").count - 1, 2)
    }

    func testRedactArgumentsKeepsTrailingFlagIntact() {
        XCTAssertEqual(ServerController.redactArguments(["--api-key"]), ["--api-key"])
    }

    func testAPIKeyNeverRidesArgvWhenEnabled() throws {
        let args = makeSettings(apiKeyEnabled: true).arguments
        XCTAssertFalse(args.contains("--api-key"),
                       "the key must not travel as an argv value (ps-visible, KES-04)")
        guard let i = args.firstIndex(of: "--api-key-file") else {
            return XCTFail("expected --api-key-file when the key is enabled")
        }
        XCTAssertGreaterThan(args.count, i + 1)
        XCTAssertTrue(args[i + 1].contains("secrets/engine-api-key"),
                      "the engine should read the key from the 0600 secret store file")
    }

    func testDiagnosticsReportOmitsTheKey() {
        var settings = makeSettings()
        settings.extraArgs = "--api-key LEAKED-VIA-EXTRA"
        let report = DiagnosticsExport.report(settings: settings, hardware: makeHardware(),
                                              logText: "sample log", extra: nil)
        XCTAssertFalse(report.contains("LEAKED-VIA-EXTRA"),
                       "diagnostics are shared files; the key must never ride them (KES-03)")
        XCTAssertTrue(report.contains("***"))
    }

    func testStartupBannerOmitsTheKey() {
        var settings = makeSettings(apiKeyEnabled: true)
        settings.extraArgs = "--api-key LEAKED-VIA-BANNER"
        let banner = ServerController.startupBanner(settings: settings)
        XCTAssertFalse(banner.contains("LEAKED-VIA-BANNER"))
    }

    func testLANRefusalNamesTheKeyRequirement() {
        XCTAssertTrue(ServerController.lanWithoutKeyRefusalMessage(language: "en")
            .localizedCaseInsensitiveContains("key"))
        XCTAssertTrue(ServerController.lanWithoutKeyRefusalMessage(language: "es")
            .localizedCaseInsensitiveContains("clave"))
    }
}
