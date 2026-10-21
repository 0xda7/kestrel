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

    // MARK: - Dictation parser (golden fixtures, G1 styles: terse resident,
    // verbose attending, ASR-noisy; all synthetic)

    /// Verbose attending style: labeled diagnoses, full implant sentence with
    /// manufacturer and lot, padded numeric phrasing.
    static let verboseDictation = """
        This is Dr. Synth dictating. Preoperative diagnosis: bilateral mammary hypoplasia. \
        Postoperative diagnosis: same. We proceeded with bilateral breast augmentation. \
        Three hundred fifty cc — dictated as 350 cc — high profile silicone gel implants \
        from Mentor, lot number SY7N421, were placed in the subpectoral plane. \
        Estimated blood loss was approximately 75 mL. There were no complications. \
        Dressing: steri-strips and a surgical bra. The patient was discharged home.
        """

    /// Terse resident style: no labels beyond EBL, newlines between facts.
    /// The unlabeled "no complications" line doubles as the fence fixture:
    /// it must parse as None without touching the dressing line below it.
    static let terseDictation = """
        left carpal tunnel release
        tourniquet time 45 minutes
        EBL 5 mL
        no complications
        dressing bacitracin and a soft wrap
        """

    /// ASR-noisy style: mangled units, stray punctuation, missing label colon.
    static let noisyDictation = """
        pre op diagnosis right breast carcinoma status post lumpectomy
        procedure reduction mammoplasty on the, right side
        blood loss approximately 200 CC
        complications, none
        """

    func testVerboseDictationParsesAllFields() {
        let parse = DictationParser.parse(Self.verboseDictation)
        XCTAssertEqual(parse.procedure?.id, "augmentation-mammoplasty")
        XCTAssertEqual(parse.fragments.preopDiagnosis, "bilateral mammary hypoplasia")
        XCTAssertEqual(parse.fragments.laterality, "bilateral")
        XCTAssertEqual(parse.fragments.ebmL, 75)
        XCTAssertEqual(parse.fragments.complications, "None")
        XCTAssertEqual(parse.fragments.dressing, "steri-strips and a surgical bra")
        XCTAssertEqual(parse.fragments.disposition, "discharged home")
    }

    func testVerboseDictationYieldsCompleteImplantRecord() throws {
        let parse = DictationParser.parse(Self.verboseDictation)
        // Exact count, not .first: the end-to-end demo once let a phantom
        // "75 mL EBL" parse as a second 75-cc implant; count fences it.
        XCTAssertEqual(parse.fragments.implants?.count, 1)
        let implant = try XCTUnwrap(parse.fragments.implants?.first)
        XCTAssertEqual(implant.kind, "silicone gel")
        XCTAssertEqual(implant.size, "350")
        XCTAssertEqual(implant.profile, "high")
        XCTAssertEqual(implant.manufacturer, "Mentor")
        XCTAssertEqual(implant.lot, "SY7N421")
    }

    func testTerseDictationParsesNumbersAndSide() throws {
        let parse = DictationParser.parse(Self.terseDictation)
        XCTAssertEqual(parse.procedure?.id, "carpal-tunnel-release")
        XCTAssertEqual(parse.fragments.laterality, "left")
        XCTAssertEqual(parse.fragments.tourniquetMinutes, 45)
        XCTAssertEqual(parse.fragments.ebmL, 5)
        XCTAssertEqual(parse.fragments.complications, "None")
        XCTAssertEqual(parse.fragments.dressing, "bacitracin and a soft wrap")
    }

    func testNoisyDictationToleratesASRNoise() throws {
        let parse = DictationParser.parse(Self.noisyDictation)
        XCTAssertEqual(parse.procedure?.id, "reduction-mammoplasty")
        XCTAssertEqual(parse.fragments.preopDiagnosis,
                       "right breast carcinoma status post lumpectomy")
        XCTAssertEqual(parse.fragments.laterality, "right")
        XCTAssertEqual(parse.fragments.ebmL, 200)
        XCTAssertEqual(parse.fragments.complications, "none")
    }

    func testLateralityAmbiguityRefusesToGuess() {
        // A revision narrative naming both sides must NOT resolve to a side.
        let ambiguous = "revision of the left breast with attention also to the right breast"
        XCTAssertNil(DictationParser.laterality(ambiguous))
    }

    func testLateralityTallyIsConservative() {
        // Both side-words present → refuse, even when one is not anatomical;
        // the safe direction under a wrong-site hazard.
        XCTAssertNil(DictationParser.laterality("the right implant was removed, tissue left intact"))
        XCTAssertEqual(DictationParser.laterality("left side only"), "left")
    }

    func testNumberWordsAreNotTrustedAsQuantities() {
        // ASR renders "one fifty" for 150: unparsed by design, never guessed.
        let parse = DictationParser.parse("breast aug bilateral, EBL one fifty")
        XCTAssertNil(parse.fragments.ebmL)
    }

    func testUnknownProcedureIsNotMatched() {
        let parse = DictationParser.parse("ribbon removal from a gift basket, EBL 0 mL")
        XCTAssertNil(parse.procedure)
        // The numeric field still parses; recognition and extraction are
        // independent failure domains.
        XCTAssertEqual(parse.fragments.ebmL, 0)
    }

    func testLongestSynonymWinsSeptorhinoplasty() {
        let parse = DictationParser.parse("septorhinoplasty performed, EBL 10 mL")
        XCTAssertEqual(parse.procedure?.id, "septorhinoplasty")
    }

    func testImplantWithoutKindStaysVisibleAsUnspecified() throws {
        let parse = DictationParser.parse("implants: 300 cc moderate profile, Mentor, lot A8811")
        let implant = try XCTUnwrap(parse.fragments.implants?.first)
        XCTAssertEqual(implant.kind, "Unspecified")
        XCTAssertEqual(implant.profile, "moderate")
        XCTAssertEqual(implant.manufacturer, "Mentor")
        XCTAssertEqual(implant.lot, "A8811")
    }

    func testTwoImplantSentencesYieldTwoRecords() {
        let parse = DictationParser.parse(
            "A 300 cc saline implant was placed on the right. A 350 cc saline implant was placed on the left.")
        XCTAssertEqual(parse.fragments.implants?.count, 2)
        XCTAssertEqual(parse.fragments.implants?.map(\.size), ["300", "350"])
    }

    func testBloodLossSentenceIsNotAPhantomImplant() throws {
        // Demo-caught: "75 mL" of EBL must not become a 75-cc implant.
        let parse = DictationParser.parse(
            "breast aug bilateral, 350 cc implants placed. Estimated blood loss was approximately 75 mL")
        XCTAssertEqual(parse.fragments.implants?.count, 1)
        XCTAssertEqual(parse.fragments.ebmL, 75)
        XCTAssertEqual(try XCTUnwrap(parse.fragments.implants?.first).size, "350")
    }

    func testLabelNeverCrossesIntoTheNextLine() throws {
        // Demo-caught: "no complications" at line end must not capture the
        // dressing dictated on the following line.
        let parse = DictationParser.parse(
            "left carpal tunnel release\nno complications\ndressing gauze and tape\n")
        XCTAssertEqual(parse.fragments.complications, "None")
        XCTAssertEqual(parse.fragments.dressing, "gauze and tape")
    }

    func testParseToBuildEndToEndNote() throws {
        // The sprint-1 exit demo as one check: dictation text in, structured
        // op note out, with the builder's gating still enforced.
        let parse = DictationParser.parse(Self.verboseDictation)
        let procedure = try XCTUnwrap(parse.procedure)
        let note = try OpNoteBuilder.build(procedure: procedure, dictated: parse.fragments)
        XCTAssertEqual(note.procedureName, "Augmentation mammoplasty")
        XCTAssertEqual(note.laterality, "Bilateral")
        XCTAssertTrue(note.renderedPlainText().contains("Mentor"))
        XCTAssertTrue(note.renderedPlainText().contains("EBL: 75 mL"))
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
    // MARK: - OpenMed-inspired v0.2: context boost, street addresses,
    // deterministic surrogates, redaction report

    func testLabeledSpaceSeparatedSSNIsMerged() {
        let result = mask("SSN: 555 01 2345 on file")
        XCTAssertFalse(result.scrubbed.contains("555 01 2345"))
        XCTAssertTrue(result.scrubbed.contains("[SSN]"))
        XCTAssertTrue(result.scrubbed.contains("SSN:"), "the label stays; only the digits are the finding")
    }

    func testLabeledNPIIsMaskedAndPlainDigitsAreNot() {
        let labeled = mask("NPI: 1234567893")
        XCTAssertTrue(labeled.scrubbed.contains("[NPI]"))
        XCTAssertFalse(labeled.scrubbed.contains("1234567893"))
        XCTAssertTrue(labeled.scrubbed.contains("NPI:"))
        // A bare 10-digit run is a phone number here, never an NPI.
        let bare = mask("call 5550102345 today")
        XCTAssertEqual(findings(bare, .npi).count, 0)
        XCTAssertEqual(findings(bare, .phone).count, 1)
    }

    func testPatientIDLabelMasksIdentifier() {
        let result = mask("patient ID: A88213-7 in the system")
        XCTAssertTrue(result.scrubbed.contains("[ID]"))
        XCTAssertFalse(result.scrubbed.contains("A88213-7"))
        XCTAssertTrue(result.scrubbed.contains("patient ID"))
    }

    func testStreetAddressIsMasked() {
        let result = mask("the patient lives at 450 Lexington Avenue now")
        XCTAssertTrue(result.scrubbed.contains("[ADDRESS]"))
        XCTAssertFalse(result.scrubbed.contains("450 Lexington Avenue"))
        XCTAssertEqual(findings(result, .streetAddress).count, 1)
    }

    static let surrogateDictation = """
        Dr. Synth evaluated the patient at 450 Lexington Avenue.
        SSN 555-01-2345, phone (555) 010-2345, patient ID: A88213-7,
        email m.calloway@midwest-care.org.
        Seen on 10/21/2026 with follow-up November 3, 2026.
        """

    func testSurrogateModeIsFullyDeterministic() {
        let first = DeIdentifier.process(Self.surrogateDictation, mode: .surrogate)
        let second = DeIdentifier.process(Self.surrogateDictation, mode: .surrogate)
        XCTAssertEqual(first.scrubbed, second.scrubbed,
                       "same document, same surrogate output — the diffability contract")
        XCTAssertFalse(first.scrubbed.contains("555-01-2345"))
        XCTAssertFalse(first.scrubbed.contains("010-2345"))
        XCTAssertFalse(first.scrubbed.contains("A88213-7"))
        XCTAssertFalse(first.scrubbed.contains("midwest-care.org"))
        XCTAssertFalse(first.scrubbed.contains("Dr. Synth"))
    }

    func testSurrogateValuesLiveInFictionalRanges() {
        let result = DeIdentifier.process(Self.surrogateDictation, mode: .surrogate)
        XCTAssertTrue(result.scrubbed.contains("555-01"), "phone surrogate in the fictional 555-01xx block")
        XCTAssertTrue(result.scrubbed.contains("900-90-"), "SSN surrogate in the unassigned 900 block")
        XCTAssertTrue(result.scrubbed.contains("@example.com"))
    }

    func testRedactionReportCountsClassesAndFlagsReview() {
        let result = mask("Dr. Synth called from Lexington about the account. SSN 555-01-2345.")
        let report = result.redactionReport()
        XCTAssertTrue(report.contains("1x[SSN]"))
        XCTAssertTrue(report.contains("1x[NAME]"))
        XCTAssertTrue(report.contains("review candidates: 1"))
    }

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
            .init(name: "testVerboseDictationParsesAllFields") { $0.testVerboseDictationParsesAllFields() },
            .init(name: "testVerboseDictationYieldsCompleteImplantRecord") { try $0.testVerboseDictationYieldsCompleteImplantRecord() },
            .init(name: "testTerseDictationParsesNumbersAndSide") { try $0.testTerseDictationParsesNumbersAndSide() },
            .init(name: "testNoisyDictationToleratesASRNoise") { try $0.testNoisyDictationToleratesASRNoise() },
            .init(name: "testLateralityAmbiguityRefusesToGuess") { $0.testLateralityAmbiguityRefusesToGuess() },
            .init(name: "testLateralityTallyIsConservative") { $0.testLateralityTallyIsConservative() },
            .init(name: "testNumberWordsAreNotTrustedAsQuantities") { $0.testNumberWordsAreNotTrustedAsQuantities() },
            .init(name: "testUnknownProcedureIsNotMatched") { $0.testUnknownProcedureIsNotMatched() },
            .init(name: "testLongestSynonymWinsSeptorhinoplasty") { $0.testLongestSynonymWinsSeptorhinoplasty() },
            .init(name: "testImplantWithoutKindStaysVisibleAsUnspecified") { try $0.testImplantWithoutKindStaysVisibleAsUnspecified() },
            .init(name: "testTwoImplantSentencesYieldTwoRecords") { $0.testTwoImplantSentencesYieldTwoRecords() },
            .init(name: "testBloodLossSentenceIsNotAPhantomImplant") { try $0.testBloodLossSentenceIsNotAPhantomImplant() },
            .init(name: "testLabelNeverCrossesIntoTheNextLine") { try $0.testLabelNeverCrossesIntoTheNextLine() },
            .init(name: "testLabeledSpaceSeparatedSSNIsMerged") { $0.testLabeledSpaceSeparatedSSNIsMerged() },
            .init(name: "testLabeledNPIIsMaskedAndPlainDigitsAreNot") { $0.testLabeledNPIIsMaskedAndPlainDigitsAreNot() },
            .init(name: "testPatientIDLabelMasksIdentifier") { $0.testPatientIDLabelMasksIdentifier() },
            .init(name: "testStreetAddressIsMasked") { $0.testStreetAddressIsMasked() },
            .init(name: "testSurrogateModeIsFullyDeterministic") { $0.testSurrogateModeIsFullyDeterministic() },
            .init(name: "testSurrogateValuesLiveInFictionalRanges") { $0.testSurrogateValuesLiveInFictionalRanges() },
            .init(name: "testRedactionReportCountsClassesAndFlagsReview") { $0.testRedactionReportCountsClassesAndFlagsReview() },
            .init(name: "testParseToBuildEndToEndNote") { try $0.testParseToBuildEndToEndNote() },
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
