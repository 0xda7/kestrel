// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: LicenseRef-Commercial

import Foundation

/// Whether an operative note for the procedure must state a side. `required`
/// procedures refuse to build a note without one — the builder never guesses.
enum LateralityKind: String, Codable, Sendable {
    case none
    case optional
    case required
}

/// One library procedure with exactly the documentation flags the op-note
/// builder gates on. Stable `id` so notes and CPT suggestions can reference
/// procedures across app versions.
struct SurgicalProcedure: Sendable, Codable, Identifiable {
    let id: String
    let name: String
    let synonyms: [String]
    let bodyRegion: String
    let laterality: LateralityKind
    let requiresImplantFields: Bool
    let requiresTourniquetField: Bool
    let cptCode: String?
}

/// The v0 procedure library: the ten procedures Kestrel Surgical documents
/// end to end. Codes are the unambiguous single CPT codes only; procedures
/// that are inherently component- or variant-coded (septorhinoplasty,
/// rhytidectomy, liposuction by site, lesion excision by site and behavior)
/// carry `nil` rather than a plausible-looking wrong suggestion.
enum ProcedureLibrary {
    static let all: [SurgicalProcedure] = [
        SurgicalProcedure(
            id: "augmentation-mammoplasty",
            name: "Augmentation mammoplasty",
            synonyms: ["breast aug", "breast augmentation", "aug mammoplasty", "breast implant surgery"],
            bodyRegion: "Breast",
            laterality: .required,
            requiresImplantFields: true,
            requiresTourniquetField: false,
            cptCode: "19325"),
        SurgicalProcedure(
            id: "reduction-mammoplasty",
            name: "Reduction mammoplasty",
            synonyms: ["breast reduction", "reduction mammaplasty"],
            bodyRegion: "Breast",
            laterality: .required,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: "19318"),
        SurgicalProcedure(
            id: "mastopexy",
            name: "Mastopexy",
            synonyms: ["breast lift"],
            bodyRegion: "Breast",
            laterality: .optional,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: "19316"),
        SurgicalProcedure(
            id: "septorhinoplasty",
            name: "Septorhinoplasty",
            synonyms: ["nose job", "rhinoplasty", "septoplasty", "septorhinoplasty"],
            bodyRegion: "Nose",
            laterality: .none,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: nil),
        SurgicalProcedure(
            id: "blepharoplasty",
            name: "Blepharoplasty",
            synonyms: ["eyelid lift", "eye lift", "eyelid surgery"],
            bodyRegion: "Eyelids",
            laterality: .optional,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: "15822"),
        SurgicalProcedure(
            id: "rhytidectomy",
            name: "Rhytidectomy",
            synonyms: ["facelift", "face lift"],
            bodyRegion: "Face",
            laterality: .none,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: nil),
        SurgicalProcedure(
            id: "liposuction",
            name: "Liposuction",
            synonyms: ["lipo", "suction lipectomy", "sal"],
            bodyRegion: "Trunk",
            laterality: .optional,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: nil),
        SurgicalProcedure(
            id: "abdominoplasty",
            name: "Abdominoplasty",
            synonyms: ["tummy tuck", "abdominoplasty with plication"],
            bodyRegion: "Abdomen",
            laterality: .none,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: "15847"),
        SurgicalProcedure(
            id: "skin-lesion-excision",
            name: "Excision of skin lesion with primary closure",
            synonyms: ["skin lesion excision", "lesion excision", "excision of lesion"],
            bodyRegion: "Skin",
            laterality: .required,
            requiresImplantFields: false,
            requiresTourniquetField: false,
            cptCode: nil),
        SurgicalProcedure(
            id: "carpal-tunnel-release",
            name: "Carpal tunnel release",
            synonyms: ["carpal tunnel", "ctr", "carpal tunnel surgery"],
            bodyRegion: "Hand",
            laterality: .required,
            requiresImplantFields: false,
            requiresTourniquetField: true,
            cptCode: "64721"),
    ]

    /// Normalized lookup key: case, whitespace and dash folded away, so
    /// "Breast-Aug", "breast aug" and "BREAST  AUG" all resolve alike.
    private static func key(_ s: String) -> String {
        s.replacingOccurrences(of: "[\\s-]", with: "", options: .regularExpression)
            .lowercased()
    }

    /// Name and synonym keys share one table; the library data is checked in
    /// and collision-free, so a duplicate key here means the data was edited
    /// wrong and trapping at first touch is the honest outcome.
    private static let byKey: [String: SurgicalProcedure] = {
        var table: [String: SurgicalProcedure] = [:]
        for procedure in all {
            table[key(procedure.name)] = procedure
            for synonym in procedure.synonyms {
                table[key(synonym)] = procedure
            }
        }
        return table
    }()

    /// Exact-after-normalization lookup by procedure name or synonym.
    /// Fuzzy prefix or fragment matching is deliberately not attempted:
    /// a wrong procedure silently templates the wrong note.
    static func find(_ query: String) -> SurgicalProcedure? {
        byKey[key(query)]
    }
}
