// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// C4 regression (live engine task 4080, 2026-11-16): a tool-call grammar the
/// bundled engine cannot compile fails sampler init server-side and used to
/// kill the whole turn. The retry contract: only grammar-constrained turns
/// retry, only once, only on the sampler/grammar failure class.
final class ToolGrammarRetryTests: CheckCase {
    private let samplerFailure = #"{"error":{"message":"Failed to initialize samplers: std::exception"}}"#

    func testSamplerInitFailureRetriesWithoutGrammar() {
        XCTAssertTrue(ChatStore.shouldRetryWithoutGrammar(
            status: 500, errorBody: samplerFailure,
            grammarConstrained: true, alreadyRetried: false))
    }

    func testUnconstrainedTurnsNeverRetry() {
        XCTAssertFalse(ChatStore.shouldRetryWithoutGrammar(
            status: 500, errorBody: samplerFailure,
            grammarConstrained: false, alreadyRetried: false))
    }

    func testRetryHappensAtMostOnce() {
        XCTAssertFalse(ChatStore.shouldRetryWithoutGrammar(
            status: 500, errorBody: samplerFailure,
            grammarConstrained: true, alreadyRetried: true))
    }

    func testOtherServerErrorsDoNotTriggerTheGrammarRetry() {
        XCTAssertFalse(ChatStore.shouldRetryWithoutGrammar(
            status: 500, errorBody: "context overflow: prompt too long",
            grammarConstrained: true, alreadyRetried: false))
        XCTAssertFalse(ChatStore.shouldRetryWithoutGrammar(
            status: 401, errorBody: "unauthorized: Invalid API Key",
            grammarConstrained: true, alreadyRetried: false))
        // 200 is never a retry — the grammar already worked.
        XCTAssertFalse(ChatStore.shouldRetryWithoutGrammar(
            status: 200, errorBody: samplerFailure,
            grammarConstrained: true, alreadyRetried: false))
    }

    func testGrammarFailureSpellingsAllMatch() {
        for body in ["grammar sampler init failed", "parse grammar: unexpected token",
                     "invalid grammar rule near 'boolean'"] {
            XCTAssertTrue(ChatStore.shouldRetryWithoutGrammar(
                status: 400, errorBody: body,
                grammarConstrained: true, alreadyRetried: false), body)
        }
    }
}

// MARK: - Generated registration (port from XCTest)
extension ToolGrammarRetryTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "ToolGrammarRetryTests",
        instance: { ToolGrammarRetryTests() },
        checks: [
            .init(name: "testSamplerInitFailureRetriesWithoutGrammar") { $0.testSamplerInitFailureRetriesWithoutGrammar() },
            .init(name: "testUnconstrainedTurnsNeverRetry") { $0.testUnconstrainedTurnsNeverRetry() },
            .init(name: "testRetryHappensAtMostOnce") { $0.testRetryHappensAtMostOnce() },
            .init(name: "testOtherServerErrorsDoNotTriggerTheGrammarRetry") { $0.testOtherServerErrorsDoNotTriggerTheGrammarRetry() },
            .init(name: "testGrammarFailureSpellingsAllMatch") { $0.testGrammarFailureSpellingsAllMatch() },
        ])
}
