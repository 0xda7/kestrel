// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

final class MetaPromptServiceTests: CheckCase {
    /// Package root, derived from this file's compile-time path
    /// (Tests/KestrelTests/MetaPromptServiceTests.swift).
    static var repoRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // Tests/KestrelTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent().path   // package root
    }

    static var stagedSystemPromptURL: URL {
        URL(fileURLWithPath: repoRoot).appendingPathComponent(
            ".agents/missions/2026-10-03-prompt-space-2/reference/meta-prompt-system.txt")
    }

    /// The embedded system prompt is a byte-for-byte port of the staged
    /// llm-space text (the file's final LF terminator is the only byte the
    /// Swift literal does not carry).
    func testSystemPromptMatchesStagedFileByteForByte() throws {
        let staged = try String(contentsOf: Self.stagedSystemPromptURL, encoding: .utf8)
        XCTAssertTrue(staged.hasSuffix("\n"), "staged file should stay LF-terminated")
        XCTAssertEqual(MetaPromptService.systemPrompt, String(staged.dropLast()))
    }

    func testArgvShapeIsConfined() {
        let argv = MetaPromptService.argv(prompt: "TASK")
        XCTAssertEqual(argv.count, 3, "unexpected argv: \(argv)")
        XCTAssertEqual(argv[0], LatchDelegateService.binaryPath)
        XCTAssertEqual(argv[1], "-p")
        // Confinement: the prompt-creator system prompt leads the task, and
        // the assembled task rides with it — one self-contained prompt.
        XCTAssertEqual(argv[2],
                       MetaPromptService.systemPrompt + "\n\n" + "TASK")
        // No session resume: the run is self-contained.
        XCTAssertFalse(argv.contains("--continue"))
        XCTAssertFalse(argv.contains("--resume"))
        XCTAssertFalse(argv.contains("--session"))
        XCTAssertFalse(argv.contains("--session-id"))
        XCTAssertFalse(argv.contains("--fork"))
        // Credentials never ride argv.
        XCTAssertFalse(argv.contains("--api-key"))
    }

    func testAssembledPromptFeedsVariablesLikeLLMSpace() {
        XCTAssertEqual(
            MetaPromptService.assembledPrompt(taskDescription: "Summarize PDFs",
                                              existingPrompt: nil, skillsList: ""),
            "Summarize PDFs")
        XCTAssertEqual(
            MetaPromptService.assembledPrompt(taskDescription: "Summarize PDFs",
                                              existingPrompt: "Old prompt",
                                              skillsList: ""),
            "Summarize PDFs\n\nExisting prompt to improve:\nOld prompt")
        XCTAssertEqual(
            MetaPromptService.assembledPrompt(taskDescription: "Summarize PDFs",
                                              existingPrompt: nil,
                                              skillsList: "- pdf_skills: extract text"),
            "Summarize PDFs\n\nAvailable skills:\n- pdf_skills: extract text")
        XCTAssertEqual(
            MetaPromptService.assembledPrompt(taskDescription: "Summarize PDFs",
                                              existingPrompt: "Old prompt",
                                              skillsList: "- pdf_skills: extract text"),
            "Summarize PDFs\n\nExisting prompt to improve:\nOld prompt"
                + "\n\nAvailable skills:\n- pdf_skills: extract text")
        // Whitespace-only optionals count as absent.
        XCTAssertEqual(
            MetaPromptService.assembledPrompt(taskDescription: "Summarize PDFs",
                                              existingPrompt: "  \n\t", skillsList: "   "),
            "Summarize PDFs")
    }

    /// The empty-task guard returns the bilingual failure text before latch
    /// is ever launched.
    @MainActor func testEmptyTaskDescriptionReturnsFailureText() async {
        let blankTask = await MetaPromptService.run(taskDescription: "   ", existingPrompt: "Old",
                                                    skillsList: "- a")
        XCTAssertEqual(blankTask, MetaPromptService.emptyTaskMessage)
        let emptyTask = await MetaPromptService.run(taskDescription: "", existingPrompt: nil,
                                                    skillsList: "")
        XCTAssertEqual(emptyTask, MetaPromptService.emptyTaskMessage)
    }

    /// Live-fire: one real run through the confined path against latch's own
    /// configured model. Opt-in via KESTREL_META_PROMPT_LIVE=1 because it
    /// spends a real model call (up to the 600 s budget).
    @MainActor func testLivePromptAuthoringRun() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_META_PROMPT_LIVE"] == "1" else {
            throw XCTSkip("Set KESTREL_META_PROMPT_LIVE=1 to run the observed-in-use latch check")
        }
        guard LatchDelegateService.isInstalled else {
            throw XCTSkip("latch is not installed at \(LatchDelegateService.binaryPath)")
        }
        let result = await MetaPromptService.run(
            taskDescription: "Classify a customer support ticket into exactly one of: "
                + "billing, bug, feature_request. Output JSON.",
            existingPrompt: "You classify tickets. Reply with the category name.",
            skillsList: "- triage_rubric: support ticket categories with examples")
        print("LIVE_META_PROMPT_RESULT >>>\n\(result)\n<<<")
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "live run returned an empty result")
        XCTAssertFalse(trimmed.hasPrefix("La descripción de la tarea está vacía"),
                       "live run hit the empty-task guard")
        XCTAssertFalse(trimmed.hasPrefix("latch completó la creación del prompt"),
                       "live run hit the empty-success guard")
        XCTAssertFalse(trimmed.hasPrefix("latch terminó de forma anómala"),
                       "live run hit the abnormal-exit guard")
        XCTAssertFalse(trimmed.contains("latch exceeded its"),
                       "live run hit the budget guard")
    }
}

// MARK: - Generated registration (port from XCTest)
extension MetaPromptServiceTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "MetaPromptServiceTests",
        instance: { MetaPromptServiceTests() },
        checks: [
            .init(name: "testSystemPromptMatchesStagedFileByteForByte") { try $0.testSystemPromptMatchesStagedFileByteForByte() },
            .init(name: "testArgvShapeIsConfined") { $0.testArgvShapeIsConfined() },
            .init(name: "testAssembledPromptFeedsVariablesLikeLLMSpace") { $0.testAssembledPromptFeedsVariablesLikeLLMSpace() },
            .init(name: "testEmptyTaskDescriptionReturnsFailureText") { await $0.testEmptyTaskDescriptionReturnsFailureText() },
            .init(name: "testLivePromptAuthoringRun") { await try $0.testLivePromptAuthoringRun() },
        ])
}
