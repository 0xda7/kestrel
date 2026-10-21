// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-3 chunk D: the census §2.8.3 Benchmarks- and Images-group
/// silent catches are surfaced. Pinned here: the health-poll timeout names
/// the last observed probe outcome instead of failing evidence-free
/// (Benchmark:341), the workload-log close feeds the typed ShareError before
/// the payload is read (BenchmarkSharing:543), image studio configuration
/// drift keeps its defaults but is recorded (ImageGen:1000-1022), an
/// unreadable config store starts fresh loudly (ImageGen:1104), the cleanup
/// scan and save paths surface through their seams (ImageGen:1280/:1304),
/// and a partially failed save-to-folder names the files that could not be
/// copied while the rest still import (ImageGenTab:1462).
///
/// Honest limitations: the AppLog lines themselves (drift, unreadable store,
/// cleanup skip, save skip, artifact size) are not observable in-harness;
/// each is pinned through the pure seam that assembles its English line
/// (driftNotice, decodeConfigs.unreadable) or, for the pure-log sites
/// (BenchmarkSharing:393 size, ImageGen:1297 cleanup, ImageGen:1320 save),
/// noted here instead of distorting the code with a test-only logging seam.
final class BenchmarkImageSurfacingTests: CheckCase {
    // MARK: - Benchmark:341 — the health-poll timeout carries probe evidence

    /// A never-healthy endpoint (transport failures) must surface the last
    /// probe error in the timeout detail, never a bare verdict.
    func testHealthTimeoutDetailNamesTheLastProbeError() {
        let detail = BenchmarkController.healthTimeoutDetail(.transport("Connection refused"))
        XCTAssertEqual(
            detail,
            "The server never became healthy; last probe error: Connection refused",
            "the timeout must name the last probe error verbatim")
    }

    /// A poll that answered but was not healthy yet is its own honest
    /// outcome — distinct from a transport error.
    func testHealthTimeoutDetailNamesAnUnhealthyResponseBody() {
        let detail = BenchmarkController.healthTimeoutDetail(.unhealthyBody("loading: 42%"))
        guard let detail else {
            return XCTFail("an unhealthy body must produce a timeout detail")
        }
        XCTAssertTrue(detail.contains("never became healthy"),
                      "the timeout must keep its verdict: \(detail)")
        XCTAssertTrue(detail.contains("was not healthy: loading: 42%"),
                      "the last probe response must be named: \(detail)")
    }

    /// Without probe evidence (e.g. the process exited before the model
    /// loaded) the detail is nil, so the caller emits the pre-existing
    /// failure line unchanged — the old surface must not regress.
    func testHealthTimeoutWithoutProbeEvidenceKeepsTheBareSurface() {
        XCTAssertNil(BenchmarkController.healthTimeoutDetail(nil),
                     "no probe evidence must leave the existing failure line untouched")
    }

    // MARK: - BenchmarkSharing:543 — the workload-log close is typed

    /// A failed close of the workload log (the share pipeline's results
    /// channel) must abort through the existing typed ShareError.workloadFailed
    /// path instead of silently risking a truncated payload.
    func testWorkloadLogCloseFailureAbortsThroughTheTypedShareError() throws {
        let enospc = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
                             userInfo: [NSLocalizedDescriptionKey: "No space left on device"])
        let failure = try XCTUnwrap(
            BenchmarkSharing.workloadLogCloseFailure(.failure(enospc)),
            "a failed close must produce the typed share error")
        guard case BenchmarkSharing.ShareError.workloadFailed(let message) = failure else {
            return XCTFail("the failure must be the existing ShareError.workloadFailed path")
        }
        XCTAssertTrue(message.contains("could not close the temporary benchmark log"),
                      "the message must name the log close: \(message)")
        XCTAssertTrue(message.contains("No space left on device"),
                      "the message must carry the close error: \(message)")
    }

    /// The success path is unchanged: a clean close produces no error.
    func testWorkloadLogCloseSuccessStaysSilent() {
        XCTAssertNil(BenchmarkSharing.workloadLogCloseFailure(.success(())),
                     "a clean close must not fabricate a failure")
    }

    // MARK: - ImageGen:1000-1022 — configuration drift keeps defaults, but is named

    /// A present-but-undecodable field (the renamed/removed-entry drift the
    /// census worries about) still decodes to the exact pre-existing default
    /// — the tolerance is unchanged — and the store decode still succeeds.
    func testPresentButUndecodableFieldsKeepThePreexistingDefaults() throws {
        let json = """
        [{"customCfg": "high", "steps": true, "modelID": "z-image-turbo"}]
        """
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(from: Data(json.utf8))
        XCTAssertNil(unreadable, "the tolerant decode must still succeed")
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.customCfg, 7.0, "the pre-existing customCfg default is unchanged")
        XCTAssertEqual(config.steps, 8, "the pre-existing steps default is unchanged")
        XCTAssertEqual(config.modelID, "z-image-turbo", "healthy fields still decode")
    }

    /// The drift line names the config id and every drifted field, in one
    /// English line per decode.
    func testConfigDriftNoticeNamesTheConfigAndEveryDriftedField() {
        XCTAssertEqual(
            ImageInstanceConfig.driftNotice(id: "abc-123", fields: ["customCfg", "steps"]),
            "Image studio configuration abc-123: field(s) [customCfg, steps] could not be read from the saved data and were reset to their defaults (possible schema drift)",
            "the drift line must name the config and every drifted field")
    }

    /// An empty payload (all keys absent — first-launch and old-version
    /// territory) decodes quietly to the defaults: no unreadable notice, no
    /// drift line.
    func testEmptyConfigPayloadDecodesQuietlyToTheDefaults() throws {
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(from: Data("[{}]".utf8))
        XCTAssertNil(unreadable, "an empty payload is a quiet decode, not drift")
        XCTAssertNil(ImageInstanceConfig.driftNotice(id: "x", fields: []),
                     "no drifted fields must produce no drift line (first-launch quiet)")
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.modelID, "")
        XCTAssertEqual(config.customCfg, 7.0)
        XCTAssertEqual(config.strength, 0.6)
        XCTAssertEqual(config.aspect, "1:1")
        XCTAssertEqual(config.baseSize, 1024)
        XCTAssertEqual(config.steps, 8)
        XCTAssertEqual(config.seed, -1)
        XCTAssertEqual(config.format, "png")
        XCTAssertEqual(config.fastMode, "off")
        XCTAssertTrue(config.referenceImagePaths.isEmpty, "the pre-existing [] default is unchanged")
    }

    /// A full valid payload decodes to exactly its written values, and the
    /// golden encode→decode round-trip is unchanged.
    func testFullConfigPayloadRoundTripsIdentically() throws {
        let json = """
        [{"id": "12345678-1234-1234-1234-123456789012", "modelID": "z-image-turbo",
          "customModelPath": "/m/custom.safetensors", "customVAEPath": "/m/vae.safetensors",
          "customTextEncoderPath": "/m/te.safetensors", "customIsDiffusion": true,
          "customCfg": 4.5, "prompt": "a lighthouse", "negativePrompt": "blurry",
          "initImagePath": "/img/init.png",
          "referenceImagePaths": ["/img/ref1.png", "/img/ref2.png"],
          "maskPath": "/img/mask.png", "strength": 0.75, "aspect": "16:9",
          "customAspect": "21:9", "baseSize": 768, "gpuIndex": 1, "auxGPUIndex": 0,
          "steps": 12, "seed": 42, "format": "jpg", "offloadCPU": true,
          "fastMode": "cache-dit"}]
        """
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(from: Data(json.utf8))
        XCTAssertNil(unreadable, "a full valid payload decodes cleanly")
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.id, UUID(uuidString: "12345678-1234-1234-1234-123456789012"))
        XCTAssertEqual(config.modelID, "z-image-turbo")
        XCTAssertEqual(config.customModelPath, "/m/custom.safetensors")
        XCTAssertEqual(config.customVAEPath, "/m/vae.safetensors")
        XCTAssertEqual(config.customTextEncoderPath, "/m/te.safetensors")
        XCTAssertEqual(config.customIsDiffusion, true)
        XCTAssertEqual(config.customCfg, 4.5)
        XCTAssertEqual(config.prompt, "a lighthouse")
        XCTAssertEqual(config.negativePrompt, "blurry")
        XCTAssertEqual(config.initImagePath, "/img/init.png")
        XCTAssertEqual(config.referenceImagePaths, ["/img/ref1.png", "/img/ref2.png"])
        XCTAssertEqual(config.maskPath, "/img/mask.png")
        XCTAssertEqual(config.strength, 0.75)
        XCTAssertEqual(config.aspect, "16:9")
        XCTAssertEqual(config.customAspect, "21:9")
        XCTAssertEqual(config.baseSize, 768)
        XCTAssertEqual(config.gpuIndex, 1)
        XCTAssertEqual(config.auxGPUIndex, 0)
        XCTAssertEqual(config.steps, 12)
        XCTAssertEqual(config.seed, 42)
        XCTAssertEqual(config.format, "jpg")
        XCTAssertEqual(config.offloadCPU, true)
        XCTAssertEqual(config.fastMode, "cache-dit")
        let redecoded = try JSONDecoder().decode([ImageInstanceConfig].self,
                                                 from: JSONEncoder().encode(configs))
        XCTAssertEqual(configs, redecoded, "the golden round-trip is unchanged")
    }

    // MARK: - ImageGen:1104 — the instance-config store load

    /// Garbage data starts fresh, and the fresh start is surfaced through the
    /// seam's English notice instead of a silent reset.
    func testGarbageConfigStoreStartsFreshWithAnEnglishNotice() throws {
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(from: Data("not json".utf8))
        XCTAssertTrue(configs.isEmpty, "garbage must not fabricate configs")
        let notice = try XCTUnwrap(unreadable, "the fresh start must be surfaced")
        XCTAssertTrue(notice.contains("Saved image studio configurations unreadable; starting fresh"),
                      "the notice must name the fresh start: \(notice)")
    }

    /// A valid store decodes to identical configs with no notice.
    func testValidConfigStoreDecodesWithoutNotice() throws {
        var config = ImageInstanceConfig()
        config.modelID = "z-image-turbo"
        config.prompt = "hola"
        let (configs, unreadable) = ImageInstanceConfig.decodeConfigs(
            from: try JSONEncoder().encode([config]))
        XCTAssertNil(unreadable, "a valid store must not be called unreadable")
        XCTAssertEqual(configs, [config], "a valid store decodes identically")
    }

    // MARK: - ImageGenTab:1462 — a partially failed save names the failed files

    /// One failing copy among several must surface the failed file's name
    /// (and only that one) while the sibling copy still succeeds — the same
    /// per-file collect-and-continue loop saveImagesToFolder runs, with a
    /// real Foundation copy failure (destination name taken by a directory).
    func testOneFailingCopyAmongSeveralSurfacesOnlyTheFailedNames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kestrel-saveall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let goodName = "good-\(UUID().uuidString).png"
        let clashName = "clash-\(UUID().uuidString).png"
        try Data([0x89]).write(to: dir.appendingPathComponent(goodName))
        let dest = dir.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        // The destination name of the clashing file is taken by a directory,
        // so exactly that one copy genuinely fails.
        try FileManager.default.createDirectory(at: dest.appendingPathComponent(clashName),
                                                withIntermediateDirectories: false)
        var failures: [(file: String, reason: String)] = []
        for name in [goodName, clashName] {
            do {
                try FileManager.default.copyItem(at: dir.appendingPathComponent(name),
                                                 to: dest.appendingPathComponent(name))
            } catch {
                failures.append((name, error.localizedDescription))
            }
        }
        XCTAssertEqual(failures.count, 1, "exactly the clashing copy must fail")
        let summary = try XCTUnwrap(
            imageCopyFailureSummary(failures, destinationName: dest.lastPathComponent),
            "a partial import must surface a summary")
        XCTAssertTrue(summary.contains(clashName), "the failed file must be named: \(summary)")
        XCTAssertTrue(summary.contains(dest.lastPathComponent),
                      "the destination must be named: \(summary)")
        XCTAssertFalse(summary.contains(goodName),
                       "the file that imported fine must not be named: \(summary)")
    }

    /// A fully successful save stays quiet.
    func testSaveAllSummaryStaysQuietWhenEveryCopySucceeds() {
        XCTAssertNil(imageCopyFailureSummary([], destinationName: "out"),
                     "a fully successful save must not raise a failure message")
    }
}

// MARK: - Generated registration (port from XCTest)
extension BenchmarkImageSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "BenchmarkImageSurfacingTests",
        instance: { BenchmarkImageSurfacingTests() },
        checks: [
            .init(name: "testConfigDriftNoticeNamesTheConfigAndEveryDriftedField") { $0.testConfigDriftNoticeNamesTheConfigAndEveryDriftedField() },
            .init(name: "testEmptyConfigPayloadDecodesQuietlyToTheDefaults") { try $0.testEmptyConfigPayloadDecodesQuietlyToTheDefaults() },
            .init(name: "testFullConfigPayloadRoundTripsIdentically") { try $0.testFullConfigPayloadRoundTripsIdentically() },
            .init(name: "testGarbageConfigStoreStartsFreshWithAnEnglishNotice") { try $0.testGarbageConfigStoreStartsFreshWithAnEnglishNotice() },
            .init(name: "testHealthTimeoutDetailNamesAnUnhealthyResponseBody") { $0.testHealthTimeoutDetailNamesAnUnhealthyResponseBody() },
            .init(name: "testHealthTimeoutDetailNamesTheLastProbeError") { $0.testHealthTimeoutDetailNamesTheLastProbeError() },
            .init(name: "testHealthTimeoutWithoutProbeEvidenceKeepsTheBareSurface") { $0.testHealthTimeoutWithoutProbeEvidenceKeepsTheBareSurface() },
            .init(name: "testOneFailingCopyAmongSeveralSurfacesOnlyTheFailedNames") { try $0.testOneFailingCopyAmongSeveralSurfacesOnlyTheFailedNames() },
            .init(name: "testPresentButUndecodableFieldsKeepThePreexistingDefaults") { try $0.testPresentButUndecodableFieldsKeepThePreexistingDefaults() },
            .init(name: "testSaveAllSummaryStaysQuietWhenEveryCopySucceeds") { $0.testSaveAllSummaryStaysQuietWhenEveryCopySucceeds() },
            .init(name: "testValidConfigStoreDecodesWithoutNotice") { try $0.testValidConfigStoreDecodesWithoutNotice() },
            .init(name: "testWorkloadLogCloseFailureAbortsThroughTheTypedShareError") { try $0.testWorkloadLogCloseFailureAbortsThroughTheTypedShareError() },
            .init(name: "testWorkloadLogCloseSuccessStaysSilent") { $0.testWorkloadLogCloseSuccessStaysSilent() },
        ])
}
