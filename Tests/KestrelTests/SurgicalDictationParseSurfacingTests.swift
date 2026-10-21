// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// Mission T2-3 chunk A: dictation regex compile failures are typed and
/// surfaced (`DictationParse.parseIssues`) instead of silently reading as
/// "field not dictated". These checks pin the compile seam's recording
/// contract and the no-false-positive guarantee on healthy parses.
final class SurgicalDictationParseSurfacingTests: CheckCase {
    // MARK: - Healthy parses (no false positives)

    /// Healthy dictations across the golden styles; every extraction path
    /// runs and every pattern compiles, so parseIssues must stay empty.
    static let healthyDictations = [
        // Verbose attending style, every field dictated.
        """
        Preoperative diagnosis: bilateral mammary hypoplasia. Postoperative diagnosis: same. \
        Bilateral breast augmentation performed. 350 cc high profile silicone gel implants \
        from Mentor, lot number SY7N421, were placed. Estimated blood loss was approximately 75 mL. \
        Tourniquet time was 45 minutes. There were no complications. Dressing: steri-strips. \
        The patient was discharged home.
        """,
        // Terse resident style.
        "left carpal tunnel release\ntourniquet time 45 minutes\nEBL 5 mL\nno complications\ndressing bacitracin and a soft wrap\n",
        // ASR-noisy style.
        "pre op diagnosis right breast carcinoma status post lumpectomy\nblood loss approximately 200 CC\ncomplications, none\n",
    ]

    func testHealthyDictationsParseWithZeroParseIssues() {
        for dictation in Self.healthyDictations {
            let parse = DictationParser.parse(dictation)
            XCTAssertEqual(parse.parseIssues, [],
                           "a healthy parse must not invent issues: \(parse.parseIssues)")
        }
    }

    // MARK: - Compile seam records typed issues, never silence

    /// The invalid pattern still refuses (nil is preserved) but the failure
    /// must be recorded as a typed issue naming the field — never silent.
    func testInvalidPatternRecordsTypedIssueNamingTheField() throws {
        var issues: [DictationParseIssue] = []
        let regex = DictationParser.compiledRegex("(", field: "EBL", recording: &issues)
        XCTAssertNil(regex, "an uncompilable pattern must still refuse to extract")
        XCTAssertEqual(issues.count, 1, "exactly one typed issue per failed compile")
        let issue = try XCTUnwrap(issues.first, "the compile failure must be recorded, not swallowed")
        XCTAssertEqual(issue.field, "EBL", "the issue must name the clinical field")
    }

    /// Every extracted field surfaces its compile failure under its own
    /// English clinical name (D3: checks are contracts).
    func testEveryFieldNamesItselfOnCompileFailure() {
        let fields = [
            "procedure", "laterality", "EBL", "tourniquet time", "implants",
            "implant kind", "implant profile", "implant manufacturer", "implant lot",
            "preoperative diagnosis", "postoperative diagnosis", "complications",
            "dressing", "disposition",
        ]
        for field in fields {
            var issues: [DictationParseIssue] = []
            XCTAssertNil(DictationParser.compiledRegex("(", field: field, recording: &issues),
                         "\(field) must still refuse on a broken pattern")
            XCTAssertEqual(issues.map(\.field), [field],
                           "the compile failure must surface under \(field)'s own name")
        }
    }

    /// The editor-renderable notice is English, names the field, and asks
    /// for review; the underlying compile error rides along as the reason.
    func testIssueNoticeIsEnglishAndNamesTheField() throws {
        var issues: [DictationParseIssue] = []
        _ = DictationParser.compiledRegex("(", field: "laterality", recording: &issues)
        let issue = try XCTUnwrap(issues.first, "the failed compile must record a typed issue")
        XCTAssertTrue(issue.editorNotice.contains("Extraction failed for laterality"),
                      "the notice must be English and name the field: \(issue.editorNotice)")
        XCTAssertTrue(issue.editorNotice.contains("review the note"),
                      "the notice must direct the surgeon to review: \(issue.editorNotice)")
        XCTAssertFalse(issue.reason.isEmpty,
                       "the underlying compile error must be carried, not discarded")
        XCTAssertEqual(issue, DictationParseIssue(field: "laterality", reason: issue.reason),
                       "issues are value types the editor can compare")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SurgicalDictationParseSurfacingTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SurgicalDictationParseSurfacingTests",
        instance: { SurgicalDictationParseSurfacingTests() },
        checks: [
            .init(name: "testHealthyDictationsParseWithZeroParseIssues") { $0.testHealthyDictationsParseWithZeroParseIssues() },
            .init(name: "testInvalidPatternRecordsTypedIssueNamingTheField") { try $0.testInvalidPatternRecordsTypedIssueNamingTheField() },
            .init(name: "testEveryFieldNamesItselfOnCompileFailure") { $0.testEveryFieldNamesItselfOnCompileFailure() },
            .init(name: "testIssueNoticeIsEnglishAndNamesTheField") { try $0.testIssueNoticeIsEnglishAndNamesTheField() },
        ])
}
