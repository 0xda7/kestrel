// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: Apache-2.0

// MedKit-bound de-identification (Safe Harbor v0, deterministic rules only).
// Staged for extraction as the standalone `kestrel-medkit` package: keep it
// Foundation-only, UI-free, and free of Kestrel app types. CryptoKit supplies
// SHA-256 for the hash mode (first-party system framework, no package
// dependency).

import CryptoKit
import Foundation

enum DeIdMode: Sendable {
    /// `[NAME]`-style bracket labels.
    case mask
    /// Fixed-width `████` block.
    case redact
    /// First 8 hex of SHA-256 of the entity string; stable per entity string.
    case hash
    /// Dates shifted by one consistent random offset per run, within ±30 days.
    case dateShift
}

/// Safe Harbor identifier classes handled by the v0 detector set.
enum DeIdKind: String, Sendable {
    case ssn
    case phone
    case fax
    case email
    case ip
    case url
    case mrn
    case date
    case deviceSerial
    case zip
    case age
    case personName
    /// Flagged for human review but deliberately NOT scrubbed: v0 trades
    /// recall for precision on ambiguous capitalized tokens.
    case reviewCandidate
}

/// One detected span. `range` indexes into the ORIGINAL text passed to
/// `process`, so findings stay auditable against the source document.
struct DeIdFinding: Sendable {
    let kind: DeIdKind
    let range: Range<String.Index>
    let original: String
}

struct DeIdResult: Sendable {
    let scrubbed: String
    let findings: [DeIdFinding]
}

struct DeIdentifier {
    static func process(_ text: String, mode: DeIdMode, knownNames: Set<String> = []) -> DeIdResult {
        // One draw per run so every date in the document moves by the same
        // offset and relative ordering survives. Zero is excluded: a 0-day
        // shift would silently make the mode a no-op.
        let offsetDays: Int = {
            guard mode == .dateShift else { return 0 }
            return (1...30).randomElement()! * (Bool.random() ? 1 : -1)
        }()

        var candidates = detect(text: text)
        candidates.append(contentsOf: detectKnownNames(text: text, knownNames: knownNames))
        let accepted = resolveOverlaps(candidates)

        var scrubbed = ""
        var cursor = text.startIndex
        for finding in accepted where finding.kind != .reviewCandidate {
            scrubbed += text[cursor..<finding.range.lowerBound]
            scrubbed += replacement(for: finding, mode: mode, offsetDays: offsetDays)
            cursor = finding.range.upperBound
        }
        scrubbed += text[cursor...]

        return DeIdResult(
            scrubbed: scrubbed,
            findings: accepted.sorted { $0.range.lowerBound < $1.range.lowerBound })
    }

    // MARK: - Replacement rules

    private static func replacement(for finding: DeIdFinding, mode: DeIdMode, offsetDays: Int) -> String {
        switch finding.kind {
        // Pinned class rules: ZIP keeps its first three digits (Safe Harbor
        // geographic granularity) and ages ≥ 90 always render the same token,
        // independent of mode.
        case .zip:
            return String(finding.original.prefix(3)) + "**"
        case .age:
            return "[AGE>89]"
        case .reviewCandidate:
            return finding.original
        case .date where mode == .dateShift:
            return shifted(finding.original, offsetDays: offsetDays)
        default:
            switch mode {
            case .mask, .dateShift:
                return maskLabel(for: finding.kind)
            case .redact:
                return "████"
            case .hash:
                return hash8(finding.original)
            }
        }
    }

    private static func maskLabel(for kind: DeIdKind) -> String {
        switch kind {
        case .ssn: "[SSN]"
        case .phone: "[PHONE]"
        case .fax: "[FAX]"
        case .email: "[EMAIL]"
        case .ip: "[IP]"
        case .url: "[URL]"
        case .mrn: "[MRN]"
        case .date: "[DATE]"
        case .deviceSerial: "[DEVICE]"
        case .zip: "[ZIP]"
        case .age: "[AGE>89]"
        case .personName: "[NAME]"
        case .reviewCandidate: ""
        }
    }

    private static func hash8(_ entity: String) -> String {
        SHA256.hash(data: Data(entity.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Date shifting

    private static func shifted(_ original: String, offsetDays: Int) -> String {
        let full = NSRange(original.startIndex..., in: original)
        for detector in dateDetectors {
            guard detector.regex.firstMatch(in: original, options: [.anchored], range: full) != nil else { continue }
            let matched = original
            for format in detector.formats {
                let parser = makeParser(format: detector.yearless ? format + " yyyy" : format)
                guard let parsed = parser.date(from: detector.yearless ? matched + " 2000" : matched) else { continue }
                let shiftedDate = parsed.addingTimeInterval(TimeInterval(offsetDays) * 86_400)
                if detector.yearless {
                    let renderer = makeParser(format: format)
                    return renderer.string(from: shiftedDate)
                }
                return parser.string(from: shiftedDate)
            }
        }
        // An unparseable candidate renders as a date label rather than
        // leaking the original; the parse step is what proved it a date.
        return "[DATE]"
    }

    private static func makeParser(format: String) -> DateFormatter {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.isLenient = false
        parser.dateFormat = format
        return parser
    }

    // MARK: - Detection

    private static func allMatches(_ regex: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }

    private static func detect(text: String) -> [DeIdFinding] {
        var findings: [DeIdFinding] = []
        func append(_ kind: DeIdKind, _ range: Range<String.Index>) {
            findings.append(DeIdFinding(kind: kind, range: range, original: String(text[range])))
        }

        for range in allMatches(ssnPattern, in: text) { append(.ssn, range) }
        for range in allMatches(phonePattern, in: text) {
            let start = text.index(range.lowerBound, offsetBy: -14, limitedBy: text.startIndex) ?? text.startIndex
            append(text[start..<range.lowerBound].lowercased().contains("fax") ? .fax : .phone, range)
        }
        for range in allMatches(emailPattern, in: text) { append(.email, range) }
        for range in allMatches(ipPattern, in: text) where isValidIPv4(String(text[range])) { append(.ip, range) }
        for range in allMatches(urlPattern, in: text) { append(.url, range) }
        for range in allMatches(mrnPattern, in: text) { append(.mrn, range) }
        for range in allMatches(serialPattern, in: text) { append(.deviceSerial, range) }
        for range in allMatches(lotPattern, in: text) { append(.deviceSerial, range) }
        // Labeled ZIP: only the digits are the finding; the label stays.
        for match in zipLabeledPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let digits = Range(match.range(at: 1), in: text) else { continue }
            append(.zip, digits)
        }
        for range in allMatches(zipPlus4Pattern, in: text) { append(.zip, range) }
        // Age: number + age phrase, flagged only at 90 and above.
        for match in agePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let value = Int(text[numberRange]),
                  let full = Range(match.range, in: text), value >= 90 else { continue }
            append(.age, full)
        }
        for range in allMatches(personPattern, in: text) { append(.personName, range) }
        for detector in dateDetectors {
            for range in allMatches(detector.regex, in: text)
            where parseDate(String(text[range]), formats: detector.formats, yearless: detector.yearless) != nil {
                append(.date, range)
            }
        }
        findings.append(contentsOf: reviewCandidates(text: text, excluding: findings))
        return findings
    }

    private static func parseDate(_ s: String, formats: [String], yearless: Bool) -> Date? {
        // Ordinal suffixes ("1st October 2026") parse on the stripped form;
        // the rendered output comes from the parsed Date, never the ordinal.
        let stripped = s.replacingOccurrences(
            of: "(?<=\\d)(?:st|nd|rd|th)\\b", with: "", options: .regularExpression)
        for format in formats {
            let parser = makeParser(format: yearless ? format + " yyyy" : format)
            if let date = parser.date(from: yearless ? stripped + " 2000" : stripped) { return date }
        }
        return nil
    }

    private static func detectKnownNames(text: String, knownNames: Set<String>) -> [DeIdFinding] {
        var findings: [DeIdFinding] = []
        for name in knownNames where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            // Caller-supplied strings are dynamic patterns: compile directly
            // and skip entries that fail, rather than trusting them.
            guard let regex = try? NSRegularExpression(
                pattern: "(?<!\\w)" + NSRegularExpression.escapedPattern(for: name) + "(?!\\w)",
                options: [.caseInsensitive]) else { continue }
            for range in allMatches(regex, in: text) {
                findings.append(DeIdFinding(kind: .personName, range: range, original: String(text[range])))
            }
        }
        return findings
    }

    /// Mid-sentence isolated capitalized tokens: left in the text, surfaced
    /// for review. Requiring lowercase words on both sides keeps sentence
    /// starts and multiword proper phrases ("The Mayo Clinic") out.
    private static func reviewCandidates(text: String, excluding accepted: [DeIdFinding]) -> [DeIdFinding] {
        var findings: [DeIdFinding] = []
        for range in allMatches(capitalizedTokenPattern, in: text) {
            let token = String(text[range]).lowercased()
            let previous = text[..<range.lowerBound].reversed().first(where: \.isLetter)
            let next = text[range.upperBound...].first(where: \.isLetter)
            guard !stopList.contains(token),
                  !accepted.contains(where: { $0.range.overlaps(range) }),
                  let previous, previous.isLowercase,
                  let next, next.isLowercase
            else { continue }
            findings.append(DeIdFinding(kind: .reviewCandidate, range: range, original: String(text[range])))
        }
        return findings
    }

    private static let stopList: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "clinic", "hospital", "medical", "health", "university", "center", "centre", "institute",
    ]

    private static func isValidIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            (1...3).contains($0.count) && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255
        }
    }

    /// Longest span wins at equal starts; otherwise the earlier span wins.
    private static func resolveOverlaps(_ candidates: [DeIdFinding]) -> [DeIdFinding] {
        let ordered = candidates.sorted {
            let a = $0.range.lowerBound, b = $1.range.lowerBound
            return a == b ? $0.range.upperBound > $1.range.upperBound : a < b
        }
        var accepted: [DeIdFinding] = []
        for finding in ordered where !accepted.contains(where: { finding.range.overlaps($0.range) }) {
            accepted.append(finding)
        }
        return accepted
    }

    // MARK: - Patterns (compile-time literals; syntax verified when written)

    private static let ssnPattern = NSRegularExpression.literal(
        pattern: "(?<!\\d)\\d{3}-\\d{2}-\\d{4}(?!\\d)")
    private static let phonePattern = NSRegularExpression.literal(
        pattern: "(?<!\\d)(?:\\+?1[\\s.-]?)?(?:\\(\\d{3}\\)|\\d{3})[\\s.-]?\\d{3}[\\s.-]?\\d{4}(?!\\d)")
    private static let emailPattern = NSRegularExpression.literal(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private static let ipPattern = NSRegularExpression.literal(
        pattern: "(?<!\\d)(?:\\d{1,3}\\.){3}\\d{1,3}(?!\\d)")
    private static let urlPattern = NSRegularExpression.literal(
        pattern: "(?:https?://|www\\.)[^\\s]+")
    private static let mrnPattern = NSRegularExpression.literal(
        pattern: "(?i)\\b(?:MRN|MR\\s*#|medical\\s+record(?:\\s+number)?)\\b\\s*[:#]?\\s*[A-Za-z0-9][A-Za-z0-9-]{2,}")
    private static let serialPattern = NSRegularExpression.literal(
        pattern: "(?i)\\bserial(?:\\s+(?:number|no\\.?))?\\s*[:#]?\\s*[A-Za-z0-9][A-Za-z0-9-]{2,}")
    // "lot" is ordinary English, so a bare "lot <word>" is not a finding;
    // the label needs "lot number"/"lot no." or a colon to count.
    private static let lotPattern = NSRegularExpression.literal(
        pattern: "(?i)\\blot\\s+(?:number|no\\.?)\\s*[:#]?\\s*[A-Za-z0-9][A-Za-z0-9-]{2,}|\\blot\\s*[:#]\\s*[A-Za-z0-9][A-Za-z0-9-]{2,}")
    private static let zipLabeledPattern = NSRegularExpression.literal(
        pattern: "(?i)\\bZIP(?:\\s*code)?\\s*[:#]?\\s*(\\d{5})(?:-\\d{4})?(?!\\d)")
    private static let zipPlus4Pattern = NSRegularExpression.literal(
        pattern: "(?<!\\d)\\d{5}-\\d{4}(?!\\d)")
    private static let agePattern = NSRegularExpression.literal(
        pattern: "(?<!\\d)(\\d{2,3})[-\\s]*(?:y/o|year[- ]old|years?[\\s]+old)\\b")
    private static let personPattern = NSRegularExpression.literal(
        pattern: "(?i:(?:Mrs|Mr|Ms|Dr|Pt))\\.?\\s+[A-Z][a-z]+(?:\\s+[A-Z][a-z]+)?")
    private static let capitalizedTokenPattern = NSRegularExpression.literal(
        pattern: "[A-Z][a-z]{2,}")

    private static let dateDetectors: [(regex: NSRegularExpression, formats: [String], yearless: Bool)] = [
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{4}-\\d{2}-\\d{2})(?!\\d)"), ["yyyy-MM-dd"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{4}/\\d{2}/\\d{2})(?!\\d)"), ["yyyy/MM/dd"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{2}\\.\\d{2}\\.\\d{4})(?!\\d)"), ["dd.MM.yyyy"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{1,2}/\\d{1,2}/\\d{2})(?!\\d)"), ["MM/dd/yy"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{1,2}/\\d{1,2}/\\d{4})(?!\\d)"), ["MM/dd/yyyy"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)([A-Za-z]+\\.?,?\\s+\\d{1,2}(?:st|nd|rd|th)?,\\s*\\d{4})(?!\\d)"),
         ["MMMM d, yyyy", "MMM. d, yyyy", "MMM d, yyyy"], false),
        (NSRegularExpression.literal(pattern: "(?<!\\d)(\\d{1,2}(?:st|nd|rd|th)?\\s+[A-Za-z]+\\.?,?\\s+\\d{4})(?!\\d)"),
         ["d MMMM yyyy", "d MMM. yyyy", "d MMM yyyy"], false),
        (NSRegularExpression.literal(pattern: "(?<![A-Za-z\\d])([A-Za-z]+\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?)(?!\\s*,?\\s*\\d{4})(?!\\d)"),
         ["MMMM d", "MMM. d", "MMM d"], true),
    ]
}
