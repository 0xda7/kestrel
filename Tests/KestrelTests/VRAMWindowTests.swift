// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The VRAM window solver must price the ubatch compute buffer: ignoring it
/// made the solver promise a ctx Metal then had to realloc past (~2× blowout
/// observed at ubatch 1024). With a fixed fake GPU, weights and KV cost, the
/// solved window must shrink as the micro-batch grows, never dip below the
/// 2048 floor, and stay untouched when everything fits.
final class VRAMWindowTests: CheckCase {
    /// 0.5 MiB per token, so KV(ctx) = ctx / 2048 GiB.
    private static let kvPerToken = 0.5 * 1_048_576

    func testSolvedWindowShrinksAsUbatchGrows() {
        let solved = { ServerSettings.solveCtx(requested: 32768, vramGB: 16, weightsGB: 8,
                                               kvPerToken: Self.kvPerToken, reserveGB: 1, ubatch: $0) }
        // Fixed cost = 8 (weights) + 0.9 (base) + ubatch term; budget 15 GiB.
        XCTAssertEqual(solved(512), 8192, "at ubatch 512 the fixed cost is 10 GiB, so 8192 tokens (4 GiB KV) is the largest power-of-two halving that fits")
        XCTAssertLessThan(solved(1024), solved(512), "doubling the micro-batch must shrink the solved window")
        XCTAssertLessThan(solved(2048), solved(1024))
        XCTAssertLessThanOrEqual(solved(4096), solved(2048), "past the floor the solver can only clamp")
    }

    func testSolverReturnsRequestedWhenItFits() {
        let solved = ServerSettings.solveCtx(requested: 32768, vramGB: 64, weightsGB: 8,
                                             kvPerToken: Self.kvPerToken, reserveGB: 1, ubatch: 4096)
        XCTAssertEqual(solved, 32768)
        // Unknown model (no KV cost) or a window at/below the floor: nothing to solve.
        XCTAssertEqual(ServerSettings.solveCtx(requested: 32768, vramGB: 16, weightsGB: 8,
                                               kvPerToken: 0, reserveGB: 1, ubatch: 4096), 32768)
        XCTAssertEqual(ServerSettings.solveCtx(requested: 2048, vramGB: 16, weightsGB: 8,
                                               kvPerToken: Self.kvPerToken, reserveGB: 1, ubatch: 4096), 2048)
        // No GPU inventory to judge against: promise what was asked.
        XCTAssertEqual(ServerSettings.solveCtx(requested: 32768, vramGB: 0, weightsGB: 8,
                                               kvPerToken: Self.kvPerToken, reserveGB: 1, ubatch: 4096), 32768)
    }

    func testSolverNeverGoesBelow2048Floor() {
        let solved = ServerSettings.solveCtx(requested: 65536, vramGB: 10, weightsGB: 9,
                                             kvPerToken: Self.kvPerToken, reserveGB: 1, ubatch: 4096)
        XCTAssertEqual(solved, 2048, "even when nothing fits, the floor holds")
    }

    func testUbatchComputeBufferCalibration() {
        XCTAssertEqual(ServerSettings.ubatchComputeBufferGB(512), 1.1, accuracy: 0.0001,
                       "the observed data point: 512 → ~1.1 GiB")
        XCTAssertEqual(ServerSettings.ubatchComputeBufferGB(1024), 2.2, accuracy: 0.0001,
                       "linear in ubatch: 1024 prices at ~2.2 GiB, over the ~2.0 observed — the safe side")
        XCTAssertEqual(ServerSettings.ubatchComputeBufferGB(0), ServerSettings.ubatchComputeBufferGB(1),
                       "degenerate values clamp to one batch, never zero or negative")
        XCTAssertGreaterThan(ServerSettings.ubatchComputeBufferGB(1024),
                             ServerSettings.ubatchComputeBufferGB(512))
    }

    func testWindowFitsVRAMBoundary() {
        // Fixed cost 0.9 + 1.1 = 2 GiB, budget 16 - 1 = 15 GiB, so KV may take 13 GiB.
        let fitsExactly = ServerSettings.windowFitsVRAM(vramGB: 16, reserveGB: 1, weightsGB: 0,
                                                        kvPerToken: 13 * 1_073_741_824, ctx: 1, ubatch: 512)
        XCTAssertTrue(fitsExactly, "equality fits: the budget is inclusive")
        let overByOneToken = ServerSettings.windowFitsVRAM(vramGB: 16, reserveGB: 1, weightsGB: 0,
                                                           kvPerToken: 13 * 1_073_741_824 + 1, ctx: 1, ubatch: 512)
        XCTAssertFalse(overByOneToken)
        // A bigger ubatch alone can push a fitting window over.
        let biggerUbatch = ServerSettings.windowFitsVRAM(vramGB: 16, reserveGB: 1, weightsGB: 0,
                                                         kvPerToken: 13 * 1_073_741_824, ctx: 1, ubatch: 1024)
        XCTAssertFalse(biggerUbatch, "doubling the micro-batch adds ~1.1 GiB of compute buffer")
    }
}

// MARK: - Generated registration (port from XCTest)
extension VRAMWindowTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "VRAMWindowTests",
        instance: { VRAMWindowTests() },
        checks: [
            .init(name: "testSolvedWindowShrinksAsUbatchGrows") { $0.testSolvedWindowShrinksAsUbatchGrows() },
            .init(name: "testSolverReturnsRequestedWhenItFits") { $0.testSolverReturnsRequestedWhenItFits() },
            .init(name: "testSolverNeverGoesBelow2048Floor") { $0.testSolverNeverGoesBelow2048Floor() },
            .init(name: "testUbatchComputeBufferCalibration") { $0.testUbatchComputeBufferCalibration() },
            .init(name: "testWindowFitsVRAMBoundary") { $0.testWindowFitsVRAMBoundary() },
        ])
}
