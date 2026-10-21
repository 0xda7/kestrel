// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// KES-01/KES-03/KES-04 regression tests: the engine key must never appear in
/// argv, logs, or diagnostics, and a keyless LAN bind must be refused.
final class SecretRedactionTests: CheckCase {
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
        let redacted = SecretRedactor.arguments(args).joined(separator: " ")
        XCTAssertFalse(redacted.contains("SECRET-ONE"))
        XCTAssertFalse(redacted.contains("SECRET-TWO"))
        XCTAssertEqual(redacted.components(separatedBy: "***").count - 1, 2)
    }

    func testRedactArgumentsKeepsTrailingFlagIntact() {
        XCTAssertEqual(SecretRedactor.arguments(["--api-key"]), ["--api-key"])
    }

    /// The `=` spelling of the same flag is the same credential: the unified
    /// redactor masks both forms (the old helper missed the `=` form).
    func testRedactorMasksEqualsFormToo() {
        XCTAssertEqual(SecretRedactor.arguments(["--api-key=EQUALS-FORM-SECRET", "-m", "/tmp/m.gguf"]),
                       ["--api-key=***", "-m", "/tmp/m.gguf"])
    }

    /// env: app-set engine vars keep their values; user-typed KEY=VALUE
    /// tokens (Extra arguments) show names only; nothing else from the
    /// inherited environment rides the line.
    func testEnvironmentLineMasksUserTokensOnly() {
        let line = SecretRedactor.environmentLine(
            environment: ["GGML_METAL_NCB": "8", "OPENAI_API_KEY": "sk-live",
                          "HOME": "/Users/operator"],
            appSetKeys: ["GGML_METAL_NCB"],
            userKeys: ["OPENAI_API_KEY"])
        XCTAssertFalse(line.contains("sk-live"))
        XCTAssertFalse(line.contains("/Users/operator"),
                       "keys the app neither set nor was handed are omitted entirely")
        XCTAssertEqual(line, "GGML_METAL_NCB=8 OPENAI_API_KEY=***")
    }

    /// URLs: userinfo (`user:pass@`) and credential-bearing query values are
    /// masked; the rest of the URL survives for debuggability, and clean
    /// text passes through unchanged.
    func testURLRedactionMasksUserinfoAndTokenQuery() {
        let masked = SecretRedactor.url("delivery to https://agent:hunter2@example.com/v1?token=abc123&x=2 failed")
        XCTAssertFalse(masked.contains("agent:"))
        XCTAssertFalse(masked.contains("hunter2"))
        XCTAssertFalse(masked.contains("abc123"))
        XCTAssertTrue(masked.contains("***@example.com/v1?token=***&x=2"),
                      "host, path and non-credential params survive: \(masked)")
        XCTAssertEqual(SecretRedactor.url("plain error text, no URL"),
                       "plain error text, no URL")
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

    func testStartupBannerMasksEnvTokensFromExtraArguments() {
        // KES-03: a KEY=VALUE env token typed into Extra arguments is a
        // credential; the banner flows into the shareable diagnostics, so
        // the value must be masked while the app-set engine vars stay whole.
        var settings = makeSettings()
        settings.extraArgs = "OPENAI_API_KEY=LEAKED-ENV-TOKEN KESTREL_MOE_UI=1"
        let banner = ServerController.startupBanner(settings: settings)
        XCTAssertFalse(banner.contains("LEAKED-ENV-TOKEN"),
                       "env tokens from Extra arguments must not ride the banner verbatim")
        XCTAssertTrue(banner.contains("OPENAI_API_KEY=***"), "the name stays for debuggability")
    }

    func testLANRefusalNamesTheKeyRequirement() {
        XCTAssertTrue(ServerController.lanWithoutKeyRefusalMessage()
            .localizedCaseInsensitiveContains("key"))
    }

    func testBrokenMaskerFailsClosedInsteadOfPassingSecretsThrough() {
        // KES-03 fail-closed: un-compilable pattern machinery must never
        // return the original text — the mask alone leaves.
        let secret = "https://alice:hunter2@example.com/x?token=sk-123"
        XCTAssertEqual(SecretRedactor.url(secret, userInfoPattern: "("), SecretRedactor.mask)
        XCTAssertEqual(SecretRedactor.url(secret, querySecretPattern: "*[invalid"), SecretRedactor.mask)
    }
}

// MARK: - Generated registration (port from XCTest)
extension SecretRedactionTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SecretRedactionTests",
        instance: { SecretRedactionTests() },
        checks: [
            .init(name: "testRedactArgumentsMasksEveryAPIKey") { $0.testRedactArgumentsMasksEveryAPIKey() },
            .init(name: "testRedactArgumentsKeepsTrailingFlagIntact") { $0.testRedactArgumentsKeepsTrailingFlagIntact() },
            .init(name: "testRedactorMasksEqualsFormToo") { $0.testRedactorMasksEqualsFormToo() },
            .init(name: "testEnvironmentLineMasksUserTokensOnly") { $0.testEnvironmentLineMasksUserTokensOnly() },
            .init(name: "testURLRedactionMasksUserinfoAndTokenQuery") { $0.testURLRedactionMasksUserinfoAndTokenQuery() },
            .init(name: "testAPIKeyNeverRidesArgvWhenEnabled") { try $0.testAPIKeyNeverRidesArgvWhenEnabled() },
            .init(name: "testDiagnosticsReportOmitsTheKey") { $0.testDiagnosticsReportOmitsTheKey() },
            .init(name: "testStartupBannerOmitsTheKey") { $0.testStartupBannerOmitsTheKey() },
            .init(name: "testStartupBannerMasksEnvTokensFromExtraArguments") { $0.testStartupBannerMasksEnvTokensFromExtraArguments() },
            .init(name: "testLANRefusalNamesTheKeyRequirement") { $0.testLANRefusalNamesTheKeyRequirement() },
            .init(name: "testBrokenMaskerFailsClosedInsteadOfPassingSecretsThrough") { $0.testBrokenMaskerFailsClosedInsteadOfPassingSecretsThrough() },
        ])
}
