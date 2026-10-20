// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Turn-budget exhaustion must read as a recoverable pause, not as the model
/// going silent mid-mission: the transcript notice names the configured
/// budget and the one-tap continue action in both languages, and the parked
/// continuation carries the real limit so the card never claims a hardcoded
/// turn count the operator isn't running.
final class AgentTurnBudgetTests: CheckCase {
    func testExhaustionNoticeNamesLimitAndContinueActionInBothLanguages() {
        for limit in [1, 7, 10, 64] {
            let notice = ChatStore.turnBudgetExhaustedNotice(limit: limit)
            XCTAssertTrue(notice.contains("\(limit)"), "the notice must name the configured limit \(limit)")
            XCTAssertTrue(notice.contains("«Continuar»"), "the Spanish half must name the one-tap continue action")
            XCTAssertTrue(notice.contains("\"Continue\""), "the English half must name the one-tap continue action")
            XCTAssertTrue(notice.contains("Misión en pausa"), "the Spanish sentence must be present")
            XCTAssertTrue(notice.contains("Mission paused"), "the English sentence must be present")
        }
    }

    func testExhaustionNoticeNamesAFreshBudgetAndKeptTranscript() {
        let notice = ChatStore.turnBudgetExhaustedNotice(limit: 7)
        XCTAssertTrue(notice.contains("presupuesto nuevo"))
        XCTAssertTrue(notice.contains("fresh budget"))
        XCTAssertTrue(notice.contains("historial intacto"))
        XCTAssertTrue(notice.contains("transcript intact"))
    }

    func testPendingContinuationCarriesTheRealTurnLimit() {
        let pending = PendingAgentContinuation(conversationID: UUID(), turnsUsed: 7,
                                               turnLimit: 7, toolsExecuted: 3)
        XCTAssertEqual(pending.turnLimit, 7)
        XCTAssertEqual(pending.turnsUsed, 7)
        XCTAssertEqual(pending.toolsExecuted, 3)
    }
}

// MARK: - Generated registration (port from XCTest)
extension AgentTurnBudgetTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "AgentTurnBudgetTests",
        instance: { AgentTurnBudgetTests() },
        checks: [
            .init(name: "testExhaustionNoticeNamesLimitAndContinueActionInBothLanguages") { $0.testExhaustionNoticeNamesLimitAndContinueActionInBothLanguages() },
            .init(name: "testExhaustionNoticeNamesAFreshBudgetAndKeptTranscript") { $0.testExhaustionNoticeNamesAFreshBudgetAndKeptTranscript() },
            .init(name: "testPendingContinuationCarriesTheRealTurnLimit") { $0.testPendingContinuationCarriesTheRealTurnLimit() },
        ])
}
