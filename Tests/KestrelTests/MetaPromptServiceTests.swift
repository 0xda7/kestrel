// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import Kestrel

final class MetaPromptServiceTests: XCTestCase {
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
        XCTAssertEqual(argv.count >= 11, true, "unexpected argv: \(argv)")
        XCTAssertEqual(argv[0], PiDelegateService.binaryPath)
        XCTAssertEqual(argv[1], "--mode")
        XCTAssertEqual(argv[2], "json")
        XCTAssertEqual(argv[3], "--session-dir")
        XCTAssertEqual(argv[4], PiDelegateService.sessionsDirectory)
        // Confinement: tools off, prompt-creator system prompt, thinking off.
        XCTAssertTrue(argv.contains("--no-tools"), "argv must confine with --no-tools")
        let systemIndex = argv.firstIndex(of: "--system-prompt")
        XCTAssertNotNil(systemIndex)
        XCTAssertEqual(argv[systemIndex! + 1], MetaPromptService.systemPrompt)
        let thinkingIndex = argv.firstIndex(of: "--thinking")
        XCTAssertNotNil(thinkingIndex)
        XCTAssertEqual(argv[thinkingIndex! + 1], "off")
        // The assembled prompt rides -p (print mode), last.
        let pIndex = argv.firstIndex(of: "-p")
        XCTAssertNotNil(pIndex)
        XCTAssertEqual(argv[pIndex! + 1], "TASK")
        XCTAssertEqual(pIndex! + 1, argv.count - 1)
        // No session resume: the run is self-contained.
        XCTAssertFalse(argv.contains("--continue"))
        XCTAssertFalse(argv.contains("--resume"))
        XCTAssertFalse(argv.contains("--session"))
        XCTAssertFalse(argv.contains("--session-id"))
        XCTAssertFalse(argv.contains("--fork"))
        // Credentials never ride argv.
        XCTAssertFalse(argv.contains("--api-key"))
        // Model/provider ride only when configured (pi's own configuration).
        XCTAssertEqual(argv.contains("--provider"),
                       !PiDelegateService.configuredProvider.isEmpty)
        XCTAssertEqual(argv.contains("--model"),
                       !PiDelegateService.configuredModel.isEmpty)
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

    /// The empty-task guard returns the bilingual failure text before pi is
    /// ever launched.
    func testEmptyTaskDescriptionReturnsFailureText() async {
        let blankTask = await MetaPromptService.run(taskDescription: "   ", existingPrompt: "Old",
                                                    skillsList: "- a")
        XCTAssertEqual(blankTask, MetaPromptService.emptyTaskMessage)
        let emptyTask = await MetaPromptService.run(taskDescription: "", existingPrompt: nil,
                                                    skillsList: "")
        XCTAssertEqual(emptyTask, MetaPromptService.emptyTaskMessage)
    }

    /// Live-fire: one real run through the confined path against pi's own
    /// configured model. Opt-in via KESTREL_META_PROMPT_LIVE=1 because it
    /// spends a real model call (up to the 600 s budget).
    func testLivePromptAuthoringRun() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_META_PROMPT_LIVE"] == "1" else {
            throw XCTSkip("Set KESTREL_META_PROMPT_LIVE=1 to run the live-fire pi check")
        }
        guard PiDelegateService.isInstalled else {
            throw XCTSkip("pi is not installed at \(PiDelegateService.binaryPath)")
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
        XCTAssertFalse(trimmed.hasPrefix("pi completó la creación del prompt"),
                       "live run hit the empty-success guard")
        XCTAssertFalse(trimmed.hasPrefix("pi terminó de forma anómala"),
                       "live run hit the abnormal-exit guard")
        XCTAssertFalse(trimmed.contains("pi excedió su presupuesto"),
                       "live run hit the budget guard")
    }
}
