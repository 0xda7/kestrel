// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: LicenseRef-Commercial

import Foundation

/// One implanted device line. `kind`/`size` are mandatory because an implant
/// line without them is untraceable; the rest is dictated when available.
struct ImplantRecord: Sendable, Codable {
    let kind: String
    let size: String
    let profile: String?
    let manufacturer: String?
    let lot: String?

    init(kind: String, size: String,
         profile: String? = nil, manufacturer: String? = nil, lot: String? = nil) {
        self.kind = kind
        self.size = size
        self.profile = profile
        self.manufacturer = manufacturer
        self.lot = lot
    }
}

/// Free-text values a dictation pass yields, before procedure rules apply.
/// Every field is optional: the builder decides what survives into the note.
struct OpNoteFragments: Sendable {
    var preopDiagnosis: String?
    var postopDiagnosis: String?
    var laterality: String?
    var implants: [ImplantRecord]?
    var ebmL: Int?
    var tourniquetMinutes: Int?
    var complications: String?
    var dressing: String?
    var disposition: String?

    init(preopDiagnosis: String? = nil,
         postopDiagnosis: String? = nil,
         laterality: String? = nil,
         implants: [ImplantRecord]? = nil,
         ebmL: Int? = nil,
         tourniquetMinutes: Int? = nil,
         complications: String? = nil,
         dressing: String? = nil,
         disposition: String? = nil) {
        self.preopDiagnosis = preopDiagnosis
        self.postopDiagnosis = postopDiagnosis
        self.laterality = laterality
        self.implants = implants
        self.ebmL = ebmL
        self.tourniquetMinutes = tourniquetMinutes
        self.complications = complications
        self.dressing = dressing
        self.disposition = disposition
    }
}

/// Structured operative note. Text sections are always present — an absent
/// dictation renders "Not dictated" so the signing surgeon sees the gap
/// instead of an empty line that prints like a completed section.
struct OpNote: Sendable, Codable {
    let preopDiagnosis: String
    let postopDiagnosis: String
    let procedureName: String
    let laterality: String
    let implants: [ImplantRecord]?
    let ebmL: Int?
    let tourniquetMinutes: Int?
    let complications: String
    let dressing: String
    let disposition: String

    /// Conventional operative-note layout: one labeled line per present
    /// section, ready to paste into an EHR or export as-is.
    func renderedPlainText() -> String {
        var lines = ["PROCEDURE NOTE"]
        lines.append("Preoperative diagnosis: \(preopDiagnosis)")
        lines.append("Postoperative diagnosis: \(postopDiagnosis)")
        lines.append("Procedure performed: \(procedureName)")
        lines.append("Laterality: \(laterality)")
        if let implants {
            for implant in implants {
                var fields = ["Kind: \(implant.kind)", "Size: \(implant.size)"]
                if let profile = implant.profile { fields.append("Profile: \(profile)") }
                if let manufacturer = implant.manufacturer { fields.append("Manufacturer: \(manufacturer)") }
                if let lot = implant.lot { fields.append("Lot: \(lot)") }
                lines.append("Implants: " + fields.joined(separator: "; "))
            }
        }
        if let ebmL { lines.append("EBL: \(ebmL) mL") }
        if let tourniquetMinutes { lines.append("Tourniquet: \(tourniquetMinutes) minutes") }
        lines.append("Complications: \(complications)")
        lines.append("Dressing: \(dressing)")
        lines.append("Disposition: \(disposition)")
        return lines.joined(separator: "\n")
    }
}

enum OpNoteError: Error, Equatable {
    /// A required side was absent or unrecognized. The builder refuses to
    /// guess: a note templated onto the wrong side is a wrong-site hazard.
    case missingLaterality
}

enum OpNoteBuilder {
    /// Sides a dictated laterality may take. Anything else is invalid —
    /// abbreviations and misspellings are not expanded, to keep the v0
    /// surface deterministic and auditable.
    private static let validSides = ["left", "right", "bilateral"]

    static func build(procedure: SurgicalProcedure, dictated: OpNoteFragments) throws -> OpNote {
        let laterality = try resolvedLaterality(procedure: procedure, dictated: dictated.laterality)
        // Implants and tourniquet exist in the note only when the procedure
        // declares them; a dictated value for an undeclared field is dropped
        // rather than rendered. EBL is documented for every procedure in the
        // library, so it rides whenever dictated.
        let implants = procedure.requiresImplantFields ? dictated.implants : nil
        let tourniquet = procedure.requiresTourniquetField ? dictated.tourniquetMinutes : nil
        return OpNote(
            preopDiagnosis: dictated.preopDiagnosis ?? notDictated,
            postopDiagnosis: dictated.postopDiagnosis ?? notDictated,
            procedureName: procedure.name,
            laterality: laterality,
            implants: (implants?.isEmpty ?? true) ? nil : implants,
            ebmL: dictated.ebmL,
            tourniquetMinutes: tourniquet,
            complications: dictated.complications ?? notDictated,
            dressing: dictated.dressing ?? notDictated,
            disposition: dictated.disposition ?? notDictated)
    }

    private static let notDictated = "Not dictated"

    private static func resolvedLaterality(procedure: SurgicalProcedure, dictated: String?) throws -> String {
        let trimmed = dictated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            switch procedure.laterality {
            case .required: throw OpNoteError.missingLaterality
            case .optional: return "Not documented"
            case .none: return "Not applicable"
            }
        }
        guard let side = validSides.first(where: { $0 == trimmed.lowercased() }) else {
            throw OpNoteError.missingLaterality
        }
        // A dictated side on a no-laterality procedure is dictation noise
        // (the face has no side); the library declaration wins.
        if procedure.laterality == .none { return "Not applicable" }
        return side.capitalized
    }
}
