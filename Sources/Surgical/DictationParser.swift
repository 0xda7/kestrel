// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: LicenseRef-Commercial

import Foundation

/// What one pass over raw dictation yields: the library procedure the text
/// names (nil when nothing recognizable), plus the structured fragments the
/// op-note builder consumes. Deterministic throughout — no model calls, no
/// randomness — so the same dictation always parses the same way, which is
/// what makes golden-fixture evaluation possible and what keeps the signing
/// surgeon's review meaningful: the parser's contribution is auditable.
struct DictationParse: Sendable {
    let procedure: SurgicalProcedure?
    var fragments: OpNoteFragments
    /// Regex compile failures met while extracting: those fields were NOT
    /// parsed and read as "not dictated" in the note. Empty on a healthy
    /// parse. The editor renders each issue instead of a silent gap.
    var parseIssues: [DictationParseIssue] = []
}

/// One clinical field whose extraction regex failed to compile: the value
/// was refused (never guessed) but must not vanish silently. `field` is the
/// English clinical field name; `reason` carries the regex compile error.
/// English-only strings, matching the product surface.
struct DictationParseIssue: Sendable, Equatable {
    let field: String
    let reason: String

    /// Editor-renderable notice naming the field and asking for review.
    var editorNotice: String {
        "Extraction failed for \(field) — the value was not parsed; review the note."
    }
}

/// Turns free-flowing surgeon dictation (typed or ASR-transcribed) into
/// structured op-note fragments. The design rule that governs every
/// extraction below: **refuse rather than guess.**
///
/// - Laterality: "left"/"right" mentioned for both sides is ambiguity, not a
///   answer — it parses to nil and the builder then refuses to template a
///   required-laterality procedure. A parser that silently picks a side is a
///   wrong-site-event generator, the one failure mode this product must
///   never have.
/// - Numbers: only digits are trusted. ASR number-words ("one fifty") are
///   left unparsed on purpose; a mis-heard volume or tourniquet time that
///   reaches the note is worse than a "Not dictated" gap the surgeon fills.
/// - Procedures: matched by library name or synonym at word boundaries,
///   longest match wins ("septorhinoplasty" is never stolen by its
///   "rhinoplasty" synonym). Nothing recognizable → nil, never the
///   closest-looking procedure.
///
/// The surface is Foundation-only and pure, mirroring the rest of the
/// surgical module: testable without the app, extractable with the product.
enum DictationParser {

    // MARK: - Procedure recognition

    /// Longest library name/synonym that occurs at word boundaries in the
    /// dictation. Longest-first ordering makes "septorhinoplasty" outrank
    /// "rhinoplasty" when both would match. Short keys (≤ 4 chars, the
    /// abbreviations: CTR, SAL, lipo…) match whole-words only so "sal" can
    /// never hit "saline"; longer keys may match a longer dictated word
    /// ("breast aug…" still finds the "breast aug" synonym).
    /// A regex compile failure still yields nil in this per-field API;
    /// `parse(_:)` records it as a typed `DictationParseIssue` instead of
    /// leaving the silence.
    static func matchProcedure(_ text: String) -> SurgicalProcedure? {
        var ignored: [DictationParseIssue] = []
        return matchProcedure(text, recording: &ignored)
    }

    private static func matchProcedure(_ text: String,
                                       recording issues: inout [DictationParseIssue]) -> SurgicalProcedure? {
        let lowered = text.lowercased()
        var best: (key: String, procedure: SurgicalProcedure)?
        for procedure in ProcedureLibrary.all {
            for name in [procedure.name] + procedure.synonyms {
                guard let regex = boundaryRegex(for: name, recording: &issues) else { continue }
                let range = NSRange(lowered.startIndex..., in: lowered)
                guard regex.firstMatch(in: lowered, range: range) != nil else { continue }
                if let current = best, name.count <= current.key.count { continue }
                best = (name, procedure)
            }
        }
        return best?.procedure
    }

    /// Word-boundary pattern for one library key: words are regex-escaped and
    /// joined with flexible separators (spaces, dashes, commas), because
    /// dictation renders "breast-aug", "breast, aug" and "breast aug" alike.
    private static func boundaryRegex(for key: String,
                                      recording issues: inout [DictationParseIssue]) -> NSRegularExpression? {
        let words = key.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        var pattern = "\\b" + escaped.joined(separator: "[\\s\\-,]+")
        if key.count <= 4 { pattern += "\\b" }
        return compiledRegex(pattern, field: "procedure",
                             options: [.caseInsensitive], recording: &issues)
    }

    /// The one regex compile seam for every dictation extraction. A compile
    /// failure records a typed `DictationParseIssue` naming the clinical
    /// field and returns nil, so extraction keeps its "refuse rather than
    /// guess" nil semantics — only the silence is removed. Internal (not
    /// private) so the surfacing checks can inject an invalid pattern and
    /// pin the recording.
    static func compiledRegex(_ pattern: String, field: String,
                              options: NSRegularExpression.Options = [],
                              recording issues: inout [DictationParseIssue]) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            issues.append(DictationParseIssue(field: field, reason: error.localizedDescription))
            return nil
        }
    }

    // MARK: - Entry point

    static func parse(_ text: String) -> DictationParse {
        var issues: [DictationParseIssue] = []
        let procedure = matchProcedure(text, recording: &issues)
        let fragments = OpNoteFragments(
            preopDiagnosis: labeledSpan(text, labels: ["preoperative diagnosis", "pre-op diagnosis", "preop diagnosis", "pre op diagnosis"],
                                        field: "preoperative diagnosis", recording: &issues),
            postopDiagnosis: labeledSpan(text, labels: ["postoperative diagnosis", "post-op diagnosis", "postop diagnosis", "post op diagnosis"],
                                         field: "postoperative diagnosis", recording: &issues),
            laterality: laterality(text, recording: &issues),
            implants: implants(text, recording: &issues),
            ebmL: ebmL(text, recording: &issues),
            tourniquetMinutes: tourniquetMinutes(text, recording: &issues),
            complications: complications(text, recording: &issues),
            dressing: labeledSpan(text, labels: ["dressing", "dressings"], field: "dressing", recording: &issues),
            disposition: disposition(text, recording: &issues))
        return DictationParse(procedure: procedure, fragments: fragments, parseIssues: issues)
    }

    // MARK: - Laterality

    /// "bilateral"/"bilaterally" wins outright. Otherwise the sides mentioned
    /// are tallied: exactly one distinct side is that side; both sides
    /// mentioned (a revision narrative legitimately names both) is ambiguity
    /// and yields nil — the builder then refuses required-laterality
    /// procedures rather than templating a guessed side.
    /// A regex compile failure still yields nil in this per-field API;
    /// `parse(_:)` records it as a typed `DictationParseIssue`.
    static func laterality(_ text: String) -> String? {
        var ignored: [DictationParseIssue] = []
        return laterality(text, recording: &ignored)
    }

    private static func laterality(_ text: String,
                                   recording issues: inout [DictationParseIssue]) -> String? {
        let lowered = text.lowercased()
        if containsWord(lowered, "bilateral", field: "laterality", recording: &issues)
            || containsWord(lowered, "bilaterally", field: "laterality", recording: &issues) {
            return "bilateral"
        }
        let left = containsWord(lowered, "left", field: "laterality", recording: &issues)
        let right = containsWord(lowered, "right", field: "laterality", recording: &issues)
        if left && !right { return "left" }
        if right && !left { return "right" }
        return nil
    }

    private static func containsWord(_ lowered: String, _ word: String, field: String,
                                     recording issues: inout [DictationParseIssue]) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        guard let regex = compiledRegex(pattern, field: field, recording: &issues) else { return false }
        let range = NSRange(lowered.startIndex..., in: lowered)
        return regex.firstMatch(in: lowered, range: range) != nil
    }

    // MARK: - Numeric fields

    /// EBL in mL. Accepts "EBL", "estimated blood loss", "blood loss" as the
    /// label, with up to a short run of non-digits ("was approximately")
    /// before the number, and mL/cc/milliliters units. cc and mL are the
    /// same volume and render as one unit in the note.
    /// A regex compile failure still yields nil in this per-field API;
    /// `parse(_:)` records it as a typed `DictationParseIssue`.
    static func ebmL(_ text: String) -> Int? {
        var ignored: [DictationParseIssue] = []
        return ebmL(text, recording: &ignored)
    }

    private static func ebmL(_ text: String, recording issues: inout [DictationParseIssue]) -> Int? {
        firstInt(text, field: "EBL", pattern:
            "(?:ebl|estimated blood loss|blood loss)[^\\d\\n]{0,40}?(\\d{1,5})\\s*(?:mls?|ccs?|milliliters?)\\b",
            recording: &issues)
    }

    /// Tourniquet minutes: "tourniquet time was 45 minutes",
    /// "tourniquet inflated for 45 min", "45 minutes of tourniquet time".
    /// A regex compile failure still yields nil in this per-field API;
    /// `parse(_:)` records it as a typed `DictationParseIssue`.
    static func tourniquetMinutes(_ text: String) -> Int? {
        var ignored: [DictationParseIssue] = []
        return tourniquetMinutes(text, recording: &ignored)
    }

    private static func tourniquetMinutes(_ text: String,
                                          recording issues: inout [DictationParseIssue]) -> Int? {
        if let direct = firstInt(text, field: "tourniquet time", pattern:
            "tourniquet(?:\\s+time)?(?:\\s+(?:was|of|at))?[^\\d\\n]{0,25}?(\\d{1,3})\\s*(?:min|minutes?)\\b",
            recording: &issues) {
            return direct
        }
        return firstInt(text, field: "tourniquet time", pattern:
            "(\\d{1,3})\\s*(?:min|minutes?)[\\s\\-]+of\\s+tourniquet\\s+time",
            recording: &issues)
    }

    /// First capture group of the pattern as an Int, or nil. Patterns are
    /// authored so the digits are the only thing that can land in the group.
    /// A compile failure records a typed issue on `field` and yields nil.
    private static func firstInt(_ text: String, field: String, pattern: String,
                                 recording issues: inout [DictationParseIssue]) -> Int? {
        guard let regex = compiledRegex(pattern, field: field,
                                        options: [.caseInsensitive], recording: &issues),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]) else { return nil }
        return value
    }

    // MARK: - Implants

    /// One record per clause that declares an implant size. Attribute windows
    /// are the surrounding sentence (split on periods/newlines), so a second
    /// implant in a later sentence becomes a second record while "350 cc
    /// implants … lot X" in one sentence stays one record with all its
    /// attributes. Kind and size are mandatory in `ImplantRecord`; a clause
    /// with a size but no explicit kind yields "Unspecified" rather than a
    /// guessed material — the gap stays visible to the signing surgeon.
    /// A regex compile failure still yields nil in this per-field API;
    /// `parse(_:)` records it as a typed `DictationParseIssue`.
    static func implants(_ text: String) -> [ImplantRecord]? {
        var ignored: [DictationParseIssue] = []
        return implants(text, recording: &ignored)
    }

    private static func implants(_ text: String,
                                 recording issues: inout [DictationParseIssue]) -> [ImplantRecord]? {
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: ".\n"))
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let sizeRegex = compiledRegex(
                  "(\\d{2,4}(?:\\.\\d)?)\\s*(?:cc|ml|milliliters?)\\b",
                  field: "implants", options: [.caseInsensitive], recording: &issues),
              let contextRegex = compiledRegex(
                "\\b(implants?|prostheses?|prosthesis|expanders?|devices?)\\b",
                field: "implants", options: [.caseInsensitive], recording: &issues) else { return nil }
        var records: [ImplantRecord] = []
        for sentence in sentences {
            // A size only counts as an implant size in a sentence that names
            // an implant: without this guard, "Estimated blood loss was
            // approximately 75 mL" parses as a phantom 75-cc implant (caught
            // live in the end-to-end demo, fenced by check ever since).
            let sentenceRange = NSRange(sentence.startIndex..., in: sentence)
            guard contextRegex.firstMatch(in: sentence, range: sentenceRange) != nil else { continue }
            guard let match = sizeRegex.firstMatch(in: sentence, range: sentenceRange),
                  let sizeRange = Range(match.range(at: 1), in: sentence) else { continue }
            let size = String(sentence[sizeRange])
            let kind = firstMatch(sentence, field: "implant kind",
                                  pattern: "\\b(saline|silicone\\s+gel|silicone|gummy\\s+bear)\\b",
                                  recording: &issues) ?? "Unspecified"
            let profile = firstMatch(sentence, field: "implant profile", pattern:
                "\\b(extra(?:\\s|-)?high|ultra(?:\\s|-)?high|high|moderate|low)\\s+profile\\b",
                recording: &issues)
            let manufacturer = firstMatch(sentence, field: "implant manufacturer", pattern:
                "\\b(mentor|allergan|sientra|ideal\\s+implant|gc\\s+aesthetics)\\b",
                recording: &issues)
            let lot = firstMatch(sentence, field: "implant lot", pattern:
                "lot(?:\\s+number)?[:\\s]+([A-Za-z0-9][A-Za-z0-9\\-]{3,})\\b",
                recording: &issues)
            records.append(ImplantRecord(
                kind: kind, size: size, profile: profile,
                manufacturer: manufacturer, lot: lot))
        }
        return records.isEmpty ? nil : records
    }

    // MARK: - Labeled spans

    /// Captures the text after a label ("Dressing:", "Preoperative
    /// diagnosis:", "complications,") to the end of the sentence or line —
    /// whichever ends first. Dictation frequently has no periods; the newline
    /// or end of input then closes the span. Separators may be a colon, dash,
    /// comma, or bare whitespace, because ASR punctuates inconsistently.
    /// The negative lookahead keeps a shorter label ("complication") from
    /// biting into a longer word ("complications") and capturing its tail.
    /// Separators are space/tab/comma/dash/colon — deliberately NOT newline:
    /// a label at a line's end owns its own line only, so "no complications"
    /// can never reach across and swallow the dressing on the next line.
    /// First label wins: a second mention of the same label later in the
    /// dictation is a correction the surgeon makes in review, not something
    /// the parser silently reconciles.
    private static func labeledSpan(_ text: String, labels: [String], field: String,
                                    recording issues: inout [DictationParseIssue]) -> String? {
        for label in labels {
            let pattern = label + "(?![A-Za-z])[ \\t,\\-:]*([^.\\n]+)"
            if let value = firstMatch(text, field: field, pattern: pattern,
                                      caseInsensitive: true, recording: &issues) {
                let cleaned = value.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func complications(_ text: String,
                                      recording issues: inout [DictationParseIssue]) -> String? {
        if let labeled = labeledSpan(text, labels: ["complications", "complication"],
                                     field: "complications", recording: &issues) {
            return labeled
        }
        // The unpunctuated spoken form ("there were no complications") is the
        // most common dictation of the cleanest outcome; recognizing it
        // verbatim keeps "None" out of the free-text slot only when actually
        // dictated.
        if text.range(of: "no complications", options: [.caseInsensitive]) != nil {
            return "None"
        }
        return nil
    }

    private static func disposition(_ text: String,
                                    recording issues: inout [DictationParseIssue]) -> String? {
        if let labeled = labeledSpan(text, labels: ["disposition"],
                                     field: "disposition", recording: &issues) {
            return labeled
        }
        // "Discharged home" is the standard endpoint; the phrase without the
        // label is still unambiguous and worth capturing.
        return firstMatch(text, field: "disposition", pattern:
            "(discharged\\s+(?:to\\s+)?home|discharged\\s+home)\\b", recording: &issues)
    }

    /// First capture group of a pattern as trimmed text, or nil. A compile
    /// failure records a typed issue on `field` and yields nil.
    private static func firstMatch(_ text: String, field: String, pattern: String,
                                   caseInsensitive: Bool = true,
                                   recording issues: inout [DictationParseIssue]) -> String? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = compiledRegex(pattern, field: field, options: options, recording: &issues),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
