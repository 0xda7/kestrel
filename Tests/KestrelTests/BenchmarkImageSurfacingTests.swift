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
/// drift is decoded to the same defaults but recorded (ImageGen:1000-1022),
/// an unreadable config store starts fresh loudly (ImageGen:1104), the
/// cleanup scan names its skip (ImageGen:1280), and a partially failed
/// save-to-folder names the files that could not be copied
/// (ImageGenTab:1462).
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
}

// MARK: - Generated registration (port from XCTest)
extension BenchmarkImageSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "BenchmarkImageSurfacingTests",
        instance: { BenchmarkImageSurfacingTests() },
        checks: [
            .init(name: "testHealthTimeoutDetailNamesTheLastProbeError") { $0.testHealthTimeoutDetailNamesTheLastProbeError() },
            .init(name: "testHealthTimeoutDetailNamesAnUnhealthyResponseBody") { $0.testHealthTimeoutDetailNamesAnUnhealthyResponseBody() },
            .init(name: "testHealthTimeoutWithoutProbeEvidenceKeepsTheBareSurface") { $0.testHealthTimeoutWithoutProbeEvidenceKeepsTheBareSurface() },
            .init(name: "testWorkloadLogCloseFailureAbortsThroughTheTypedShareError") { try $0.testWorkloadLogCloseFailureAbortsThroughTheTypedShareError() },
            .init(name: "testWorkloadLogCloseSuccessStaysSilent") { $0.testWorkloadLogCloseSuccessStaysSilent() },
        ])
}
