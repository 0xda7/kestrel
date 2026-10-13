// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
@testable import KestrelCore

/// Surgical sprint 1: the procedure library, the op-note builder's gating
/// rules, and the de-identifier's Safe Harbor v0 detector set. All fixtures
/// are synthetic; nothing here resembles a real patient.
final class SurgicalChecks: CheckCase {
    // MARK: - Fixtures

    private func procedure(_ query: String) -> SurgicalProcedure {
        guard let found = ProcedureLibrary.find(query) else {
            XCTFail("library lookup failed for '\(query)'")
            return ProcedureLibrary.all[0]
        }
        return found
    }

    private func mask(_ text: String, knownNames: Set<String> = []) -> DeIdResult {
        DeIdentifier.process(text, mode: .mask, knownNames: knownNames)
    }

    private func findings(_ result: DeIdResult, _ kind: DeIdKind) -> [DeIdFinding] {
        result.findings.filter { $0.kind == kind }
    }

    private func sha8(_ entity: String) -> String {
        SHA256.hash(data: Data(entity.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isoDate(_ s: String) -> Date? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: s)
    }

    private func isoDates(in text: String) -> [String] {
        let regex = NSRegularExpression.literal(pattern: "(?<!\\d)\\d{4}-\\d{2}-\\d{2}(?!\\d)")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }.map { String(text[$0]) }
    }

    // MARK: - Procedure library

    func testLibraryCarriesExactlyTheTenSpecProcedures() {
        let expected: Set<String> = [
            "augmentation-mammoplasty", "reduction-mammoplasty", "mastopexy",
            "septorhinoplasty", "blepharoplasty", "rhytidectomy", "liposuction",
            "abdominoplasty", "skin-lesion-excision", "carpal-tunnel-release",
        ]
        XCTAssertEqual(ProcedureLibrary.all.count, 10)
        XCTAssertEqual(Set(ProcedureLibrary.all.map(\.id)), expected)
    }

    func testProcedureIdentifiersAreUnique() {
        XCTAssertEqual(Set(ProcedureLibrary.all.map(\.id)).count, ProcedureLibrary.all.count)
    }

    func testSynonymLookupCoversBreastAug() {
        for spelling in ["breast aug", "BREAST AUG", "breast-aug", "Breast Augmentation"] {
            XCTAssertEqual(procedure(spelling).id, "augmentation-mammoplasty", spelling)
        }
    }

    func testSynonymLookupCoversTummyTuck() {
        for spelling in ["tummy tuck", "Tummy-Tuck", "abdominoplasty"] {
            XCTAssertEqual(procedure(spelling).id, "abdominoplasty", spelling)
        }
    }

    func testSynonymLookupCoversFacelift() {
        XCTAssertEqual(procedure("facelift").id, "rhytidectomy")
        XCTAssertEqual(procedure("face lift").id, "rhytidectomy")
        XCTAssertEqual(procedure("Rhytidectomy").id, "rhytidectomy")
    }

    func testSynonymLookupCoversEyelidLift() {
        XCTAssertEqual(procedure("eyelid lift").id, "blepharoplasty")
        XCTAssertEqual(procedure("Eyelid Surgery").id, "blepharoplasty")
    }

    func testSynonymLookupCoversCarpalTunnel() {
        XCTAssertEqual(procedure("carpal tunnel").id, "carpal-tunnel-release")
        XCTAssertEqual(procedure("Carpal Tunnel Release").id, "carpal-tunnel-release")
        XCTAssertEqual(procedure("CTR").id, "carpal-tunnel-release")
    }

    func testLateralityDeclarationsMatchTheSpec() {
        let expected: [String: LateralityKind] = [
            "augmentation-mammoplasty": .required,
            "reduction-mammoplasty": .required,
            "mastopexy": .optional,
            "septorhinoplasty": .none,
            "blepharoplasty": .optional,
            "rhytidectomy": .none,
            "liposuction": .optional,
            "abdominoplasty": .none,
            "skin-lesion-excision": .required,
            "carpal-tunnel-release": .required,
        ]
        for found in ProcedureLibrary.all {
            XCTAssertEqual(found.laterality, expected[found.id], found.id)
        }
    }

    func testUnknownQueryReturnsNil() {
        XCTAssertNil(ProcedureLibrary.find("Not a real procedure"))
        XCTAssertNil(ProcedureLibrary.find(""))
        XCTAssertNil(ProcedureLibrary.find("  "))
    }

    // MARK: - Op-note builder

    func testHappyPathBuildsCompleteNote() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("breast aug"),
            dictated: OpNoteFragments(
                preopDiagnosis: "Bilateral mammary hypoplasia",
                postopDiagnosis: "Bilateral mammary hypoplasia",
                laterality: "bilateral",
                implants: [ImplantRecord(
                    kind: "smooth round silicone", size: "325 cc",
                    profile: "moderate plus", manufacturer: "TestDevices Medical",
                    lot: "LOT-88213")],
                ebmL: 40,
                complications: "None",
                dressing: "Steri-strips and surgical bra",
                disposition: "Home with escort"))
        XCTAssertEqual(note.procedureName, "Augmentation mammoplasty")
        XCTAssertEqual(note.laterality, "Bilateral")
        XCTAssertEqual(note.implants?.count, 1)
        XCTAssertEqual(note.implants?.first?.lot, "LOT-88213")
        XCTAssertEqual(note.ebmL, 40)
        XCTAssertEqual(note.complications, "None")
    }

    func testRequiredLateralityMissingThrows() {
        let reduction = procedure("breast reduction")
        XCTAssertThrowsError(try OpNoteBuilder.build(
            procedure: reduction,
            dictated: OpNoteFragments(preopDiagnosis: "Symptomatic macromastia"))) { error in
            XCTAssertEqual(error as? OpNoteError, .missingLaterality)
        }
    }

    func testRequiredLateralityInvalidThrows() {
        let reduction = procedure("breast reduction")
        XCTAssertThrowsError(try OpNoteBuilder.build(
            procedure: reduction,
            dictated: OpNoteFragments(laterality: "sideways"))) { error in
            XCTAssertEqual(error as? OpNoteError, .missingLaterality)
        }
    }

    func testOptionalLateralityAbsentRendersNotDocumented() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("mastopexy"),
            dictated: OpNoteFragments(preopDiagnosis: "Ptosis"))
        XCTAssertEqual(note.laterality, "Not documented")
    }

    func testNoneLateralityRendersNotApplicableEvenWhenDictated() throws {
        let rhytidectomy = procedure("facelift")
        let note = try OpNoteBuilder.build(
            procedure: rhytidectomy,
            dictated: OpNoteFragments(laterality: "left"))
        XCTAssertEqual(note.laterality, "Not applicable")
        let quiet = try OpNoteBuilder.build(procedure: rhytidectomy, dictated: OpNoteFragments())
        XCTAssertEqual(quiet.laterality, "Not applicable")
    }

    func testImplantFieldsGatedByProcedureDeclaration() throws {
        let reduction = procedure("breast reduction")
        let note = try OpNoteBuilder.build(
            procedure: reduction,
            dictated: OpNoteFragments(
                laterality: "left",
                implants: [ImplantRecord(kind: "spacer", size: "1")]))
        XCTAssertNil(note.implants, "reduction declares no implant fields; the dictation must not leak in")
        let augmentation = procedure("breast aug")
        let without = try OpNoteBuilder.build(
            procedure: augmentation,
            dictated: OpNoteFragments(laterality: "right"))
        XCTAssertNil(without.implants)
    }

    func testTourniquetMinutesGatedByProcedureDeclaration() throws {
        let augmentation = procedure("breast aug")
        let note = try OpNoteBuilder.build(
            procedure: augmentation,
            dictated: OpNoteFragments(laterality: "right", tourniquetMinutes: 30))
        XCTAssertNil(note.tourniquetMinutes, "augmentation declares no tourniquet field")
        let carpalTunnel = procedure("carpal tunnel")
        let gated = try OpNoteBuilder.build(
            procedure: carpalTunnel,
            dictated: OpNoteFragments(laterality: "left", tourniquetMinutes: 25))
        XCTAssertEqual(gated.tourniquetMinutes, 25)
    }

    func testEblRidesWheneverDictated() throws {
        let reduction = procedure("breast reduction")
        let note = try OpNoteBuilder.build(
            procedure: reduction,
            dictated: OpNoteFragments(laterality: "bilateral", ebmL: 75))
        XCTAssertEqual(note.ebmL, 75)
        let quiet = try OpNoteBuilder.build(
            procedure: procedure("mastopexy"), dictated: OpNoteFragments())
        XCTAssertNil(quiet.ebmL)
    }

    func testRenderedNoteCarriesProcedureLateralityAndDiagnoses() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("breast reduction"),
            dictated: OpNoteFragments(
                preopDiagnosis: "Symptomatic macromastia",
                postopDiagnosis: "Symptomatic macromastia",
                laterality: "left"))
        let rendered = note.renderedPlainText()
        XCTAssertTrue(rendered.contains("Procedure performed: Reduction mammoplasty"))
        XCTAssertTrue(rendered.contains("Laterality: Left"))
        XCTAssertTrue(rendered.contains("Preoperative diagnosis: Symptomatic macromastia"))
        XCTAssertTrue(rendered.contains("Postoperative diagnosis: Symptomatic macromastia"))
    }

    func testRenderedNoteCarriesImplantDetails() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("breast aug"),
            dictated: OpNoteFragments(
                laterality: "bilateral",
                implants: [ImplantRecord(
                    kind: "smooth round silicone", size: "325 cc",
                    profile: "moderate plus", manufacturer: "TestDevices Medical",
                    lot: "LOT-88213")]))
        let rendered = note.renderedPlainText()
        XCTAssertTrue(rendered.contains("Implants: Kind: smooth round silicone; Size: 325 cc"))
        XCTAssertTrue(rendered.contains("Profile: moderate plus"))
        XCTAssertTrue(rendered.contains("Lot: LOT-88213"))
    }

    func testRenderedNoteCarriesTourniquetAndEbl() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("carpal tunnel"),
            dictated: OpNoteFragments(
                laterality: "left", ebmL: 5, tourniquetMinutes: 25,
                disposition: "Home with escort"))
        let rendered = note.renderedPlainText()
        XCTAssertTrue(rendered.contains("Tourniquet: 25 minutes"))
        XCTAssertTrue(rendered.contains("EBL: 5 mL"))
        XCTAssertTrue(rendered.contains("Disposition: Home with escort"))
    }

    func testOpNoteRoundTripsThroughCodable() throws {
        let note = try OpNoteBuilder.build(
            procedure: procedure("breast aug"),
            dictated: OpNoteFragments(
                preopDiagnosis: "Bilateral mammary hypoplasia",
                postopDiagnosis: "Bilateral mammary hypoplasia",
                laterality: "bilateral",
                implants: [ImplantRecord(
                    kind: "smooth round silicone", size: "325 cc", lot: "LOT-88213")],
                ebmL: 40))
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(OpNote.self, from: data)
        XCTAssertEqual(decoded.procedureName, note.procedureName)
        XCTAssertEqual(decoded.laterality, note.laterality)
        XCTAssertEqual(decoded.implants?.first?.lot, "LOT-88213")
        XCTAssertEqual(decoded.ebmL, note.ebmL)
        XCTAssertEqual(decoded.disposition, note.disposition)
    }

    // MARK: - De-identification

    func testSSNIsMaskedAndReported() {
        let result = mask("SSN 555-01-2345 on file.")
        XCTAssertFalse(result.scrubbed.contains("555-01-2345"))
        XCTAssertTrue(result.scrubbed.contains("[SSN]"))
        XCTAssertEqual(findings(result, .ssn).first?.original, "555-01-2345")
    }

    func testPhoneFormatsAreMasked() {
        let result = mask("call 555.123.4567 or 555 123 4568.")
        XCTAssertEqual(findings(result, .phone).count, 2)
        XCTAssertFalse(result.scrubbed.contains("555.123.4567"))
        XCTAssertFalse(result.scrubbed.contains("555 123 4568"))
        XCTAssertTrue(result.scrubbed.contains("[PHONE]"))
    }

    func testLabeledFaxIsClassifiedAsFax() {
        let result = mask("Fax: (555) 123-4567 at the front desk.")
        XCTAssertFalse(result.scrubbed.contains("123-4567"))
        XCTAssertTrue(result.scrubbed.contains("[FAX]"))
        XCTAssertEqual(findings(result, .fax).count, 1)
        XCTAssertEqual(findings(result, .phone).count, 0)
    }

    func testEmailIsMasked() {
        let result = mask("Contact john.doe@example.invalid for results.")
        XCTAssertFalse(result.scrubbed.contains("john.doe@example.invalid"))
        XCTAssertFalse(result.scrubbed.contains("@"))
        XCTAssertTrue(result.scrubbed.contains("[EMAIL]"))
        XCTAssertEqual(findings(result, .email).first?.original, "john.doe@example.invalid")
    }

    func testIPv4AddressIsMasked() {
        let result = mask("The scanner at 192.168.1.10 failed.")
        XCTAssertFalse(result.scrubbed.contains("192.168.1.10"))
        XCTAssertTrue(result.scrubbed.contains("[IP]"))
        XCTAssertEqual(findings(result, .ip).first?.original, "192.168.1.10")
    }

    func testURLIsMasked() {
        let result = mask("Records at https://records.example.invalid/pt/448821 today.")
        XCTAssertFalse(result.scrubbed.contains("https://records.example.invalid"))
        XCTAssertTrue(result.scrubbed.contains("[URL]"))
        XCTAssertEqual(findings(result, .url).count, 1)
    }

    func testLabeledMRNIsMasked() {
        let result = mask("MRN: 448821 in the chart.")
        XCTAssertFalse(result.scrubbed.contains("448821"))
        XCTAssertTrue(result.scrubbed.contains("[MRN]"))
        XCTAssertEqual(findings(result, .mrn).first?.original, "MRN: 448821")
    }

    func testDatesAcrossEightFormatsAreDetected() {
        let formats = [
            "2026-04-01", "2026/04/01", "01.04.2026", "04/01/26",
            "04/01/2026", "April 1, 2026", "1 April 2026", "April 1",
        ]
        for spelling in formats {
            let result = mask("Dated \(spelling) in chart.")
            XCTAssertEqual(findings(result, .date).count, 1, spelling)
            XCTAssertFalse(result.scrubbed.contains(spelling), spelling)
            XCTAssertTrue(result.scrubbed.contains("[DATE]"), spelling)
        }
    }

    func testDeviceSerialAndLotAreMasked() {
        let result = mask("Serial: SN-99120 and lot number L-8842 on the implant.")
        XCTAssertEqual(findings(result, .deviceSerial).count, 2)
        XCTAssertFalse(result.scrubbed.contains("SN-99120"))
        XCTAssertFalse(result.scrubbed.contains("L-8842"))
        XCTAssertTrue(result.scrubbed.contains("[DEVICE]"))
    }

    func testZipKeepsThreeDigits() {
        let result = mask("Ships to ZIP: 90210 tomorrow.")
        XCTAssertTrue(result.scrubbed.contains("902**"))
        XCTAssertFalse(result.scrubbed.contains("90210"))
        XCTAssertEqual(findings(result, .zip).first?.original, "90210")
    }

    func testAgeBoundaryScrubbedAtNinetyOnly() {
        let result = mask("The first patient is 89 years old and the second is 90 y/o.")
        XCTAssertTrue(result.scrubbed.contains("89 years old"))
        XCTAssertFalse(result.scrubbed.contains("90 y/o"))
        XCTAssertTrue(result.scrubbed.contains("[AGE>89]"))
        XCTAssertEqual(findings(result, .age).count, 1)
    }

    func testHonorificNamesAreMasked() {
        let result = mask("Dr. Smith and Pt. Diaz attended.")
        XCTAssertFalse(result.scrubbed.contains("Smith"))
        XCTAssertFalse(result.scrubbed.contains("Diaz"))
        XCTAssertEqual(findings(result, .personName).count, 2)
        XCTAssertTrue(result.scrubbed.contains("[NAME]"))
    }

    func testKnownNamesRosterIsMasked() {
        let result = mask("Jane Roe returned for sutures.", knownNames: ["Jane Roe"])
        XCTAssertFalse(result.scrubbed.contains("Jane Roe"))
        XCTAssertEqual(findings(result, .personName).first?.original, "Jane Roe")
    }

    func testOrganizationNamesSurviveScrubbing() {
        let result = mask("Dr. Smith referred the patient to The Mayo Clinic.")
        XCTAssertFalse(result.scrubbed.contains("Smith"))
        XCTAssertTrue(result.scrubbed.contains("The Mayo Clinic"))
        XCTAssertEqual(findings(result, .personName).count, 1,
                       "only the honorific name is a person finding")
    }

    func testReviewCandidateFlaggedButNotRemoved() {
        let text = "The resident was assisted by Smith today."
        let result = mask(text)
        XCTAssertEqual(result.scrubbed, text, "ambiguous tokens stay in the text")
        XCTAssertEqual(findings(result, .reviewCandidate).first?.original, "Smith")
        XCTAssertEqual(findings(result, .personName).count, 0)
    }

    func testMaskModeUsesBracketLabelsPerClass() {
        let result = mask("SSN 555-01-2345, phone 555-123-4567, email john.doe@example.invalid.")
        XCTAssertTrue(result.scrubbed.contains("[SSN]"))
        XCTAssertTrue(result.scrubbed.contains("[PHONE]"))
        XCTAssertTrue(result.scrubbed.contains("[EMAIL]"))
        XCTAssertFalse(result.scrubbed.contains("555-01-2345"))
        XCTAssertFalse(result.scrubbed.contains("555-123-4567"))
        XCTAssertFalse(result.scrubbed.contains("john.doe@example.invalid"))
    }

    func testRedactModeProducesFixedWidthBlocks() {
        let result = DeIdentifier.process("SSN 555-01-2345 and MRN: 448821.", mode: .redact)
        XCTAssertEqual(result.scrubbed.components(separatedBy: "████").count - 1, 2)
        XCTAssertFalse(result.scrubbed.contains("█████"), "blocks stay fixed-width")
        XCTAssertFalse(result.scrubbed.contains("555-01-2345"))
        XCTAssertFalse(result.scrubbed.contains("448821"))
    }

    func testHashModeIsStablePerEntityWithinARun() {
        let text = "SSN 555-01-2345 checked against 555-01-2345 and MRN: 448821."
        let result = DeIdentifier.process(text, mode: .hash)
        let expected = sha8("555-01-2345")
        XCTAssertFalse(result.scrubbed.contains("555-01-2345"))
        XCTAssertEqual(result.scrubbed.components(separatedBy: expected).count - 1, 2,
                       "the same entity hashes to the same token inside one run")
        XCTAssertTrue(expected.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(expected.count, 8)
        XCTAssertNotEqual(expected, sha8("MRN: 448821"))
        XCTAssertTrue(result.scrubbed.contains(sha8("MRN: 448821")))
    }

    func testDateShiftMovesAllDatesByOneOffsetWithinThirtyDays() {
        let text = "Surgery on 2026-01-05 with follow-up on 2026-03-20."
        let original = ["2026-01-05", "2026-03-20"].compactMap(isoDate)
        for _ in 0..<5 {
            let result = DeIdentifier.process(text, mode: .dateShift)
            let shifted = isoDates(in: result.scrubbed)
            XCTAssertEqual(shifted.count, 2)
            XCTAssertFalse(result.scrubbed.contains("2026-01-05"))
            XCTAssertFalse(result.scrubbed.contains("2026-03-20"))
            let shiftedDates = shifted.compactMap(isoDate)
            XCTAssertEqual(shiftedDates.count, 2)
            let deltas = zip(shiftedDates, original).map { $0.timeIntervalSince($1) }
            XCTAssertEqual(deltas[0], deltas[1], accuracy: 1,
                           "one run shifts every date by the same offset")
            let days = deltas[0] / 86_400
            XCTAssertGreaterThanOrEqual(abs(days), 1, "a 0-day shift would be a silent no-op")
            XCTAssertLessThanOrEqual(abs(days), 30)
            XCTAssertLessThan(shiftedDates[0], shiftedDates[1], "ordering is preserved")
        }
    }

    func testFindingsCarryOriginalTextAndResolvableRange() {
        let text = "MRN: 448821 in chart."
        let result = mask(text)
        guard let finding = findings(result, .mrn).first else {
            return XCTFail("expected an MRN finding")
        }
        XCTAssertEqual(finding.original, "MRN: 448821")
        XCTAssertEqual(String(text[finding.range]), finding.original,
                       "the finding range indexes into the original text")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SurgicalChecks {
    @MainActor static let __checkSet = CheckSet(
        suite: "SurgicalChecks",
        instance: { SurgicalChecks() },
        checks: [
            .init(name: "testLibraryCarriesExactlyTheTenSpecProcedures") { $0.testLibraryCarriesExactlyTheTenSpecProcedures() },
            .init(name: "testProcedureIdentifiersAreUnique") { $0.testProcedureIdentifiersAreUnique() },
            .init(name: "testSynonymLookupCoversBreastAug") { $0.testSynonymLookupCoversBreastAug() },
            .init(name: "testSynonymLookupCoversTummyTuck") { $0.testSynonymLookupCoversTummyTuck() },
            .init(name: "testSynonymLookupCoversFacelift") { $0.testSynonymLookupCoversFacelift() },
            .init(name: "testSynonymLookupCoversEyelidLift") { $0.testSynonymLookupCoversEyelidLift() },
            .init(name: "testSynonymLookupCoversCarpalTunnel") { $0.testSynonymLookupCoversCarpalTunnel() },
            .init(name: "testLateralityDeclarationsMatchTheSpec") { $0.testLateralityDeclarationsMatchTheSpec() },
            .init(name: "testUnknownQueryReturnsNil") { $0.testUnknownQueryReturnsNil() },
            .init(name: "testHappyPathBuildsCompleteNote") { try $0.testHappyPathBuildsCompleteNote() },
            .init(name: "testRequiredLateralityMissingThrows") { $0.testRequiredLateralityMissingThrows() },
            .init(name: "testRequiredLateralityInvalidThrows") { $0.testRequiredLateralityInvalidThrows() },
            .init(name: "testOptionalLateralityAbsentRendersNotDocumented") { try $0.testOptionalLateralityAbsentRendersNotDocumented() },
            .init(name: "testNoneLateralityRendersNotApplicableEvenWhenDictated") { try $0.testNoneLateralityRendersNotApplicableEvenWhenDictated() },
            .init(name: "testImplantFieldsGatedByProcedureDeclaration") { try $0.testImplantFieldsGatedByProcedureDeclaration() },
            .init(name: "testTourniquetMinutesGatedByProcedureDeclaration") { try $0.testTourniquetMinutesGatedByProcedureDeclaration() },
            .init(name: "testEblRidesWheneverDictated") { try $0.testEblRidesWheneverDictated() },
            .init(name: "testRenderedNoteCarriesProcedureLateralityAndDiagnoses") { try $0.testRenderedNoteCarriesProcedureLateralityAndDiagnoses() },
            .init(name: "testRenderedNoteCarriesImplantDetails") { try $0.testRenderedNoteCarriesImplantDetails() },
            .init(name: "testRenderedNoteCarriesTourniquetAndEbl") { try $0.testRenderedNoteCarriesTourniquetAndEbl() },
            .init(name: "testOpNoteRoundTripsThroughCodable") { try $0.testOpNoteRoundTripsThroughCodable() },
            .init(name: "testSSNIsMaskedAndReported") { $0.testSSNIsMaskedAndReported() },
            .init(name: "testPhoneFormatsAreMasked") { $0.testPhoneFormatsAreMasked() },
            .init(name: "testLabeledFaxIsClassifiedAsFax") { $0.testLabeledFaxIsClassifiedAsFax() },
            .init(name: "testEmailIsMasked") { $0.testEmailIsMasked() },
            .init(name: "testIPv4AddressIsMasked") { $0.testIPv4AddressIsMasked() },
            .init(name: "testURLIsMasked") { $0.testURLIsMasked() },
            .init(name: "testLabeledMRNIsMasked") { $0.testLabeledMRNIsMasked() },
            .init(name: "testDatesAcrossEightFormatsAreDetected") { $0.testDatesAcrossEightFormatsAreDetected() },
            .init(name: "testDeviceSerialAndLotAreMasked") { $0.testDeviceSerialAndLotAreMasked() },
            .init(name: "testZipKeepsThreeDigits") { $0.testZipKeepsThreeDigits() },
            .init(name: "testAgeBoundaryScrubbedAtNinetyOnly") { $0.testAgeBoundaryScrubbedAtNinetyOnly() },
            .init(name: "testHonorificNamesAreMasked") { $0.testHonorificNamesAreMasked() },
            .init(name: "testKnownNamesRosterIsMasked") { $0.testKnownNamesRosterIsMasked() },
            .init(name: "testOrganizationNamesSurviveScrubbing") { $0.testOrganizationNamesSurviveScrubbing() },
            .init(name: "testReviewCandidateFlaggedButNotRemoved") { $0.testReviewCandidateFlaggedButNotRemoved() },
            .init(name: "testMaskModeUsesBracketLabelsPerClass") { $0.testMaskModeUsesBracketLabelsPerClass() },
            .init(name: "testRedactModeProducesFixedWidthBlocks") { $0.testRedactModeProducesFixedWidthBlocks() },
            .init(name: "testHashModeIsStablePerEntityWithinARun") { $0.testHashModeIsStablePerEntityWithinARun() },
            .init(name: "testDateShiftMovesAllDatesByOneOffsetWithinThirtyDays") { $0.testDateShiftMovesAllDatesByOneOffsetWithinThirtyDays() },
            .init(name: "testFindingsCarryOriginalTextAndResolvableRange") { $0.testFindingsCarryOriginalTextAndResolvableRange() },
        ])
}
