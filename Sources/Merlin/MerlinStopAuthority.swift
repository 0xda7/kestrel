// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The M6 Stop Authority's progress detector.
///
/// Budget exhaustion is the kernel's job (the turn budget lives in
/// MerlinKernel; this type does NOT duplicate it). What the budget cannot
/// see is the *shape* of the turns inside it: a ≤9B model burning its whole
/// budget re-issuing the same failing call. The detector fingerprints each
/// executed call as a result signature — tool + normalized arguments +
/// outcome class — and demands wrap-up when N identical signatures arrive
/// back to back.
///
/// Wrap-up is advisory to the model, authoritative to the ledger: the
/// kernel injects a blocker ("no progress detected; either change approach
/// or file task_done with what exists") and the spine renders it through
/// `wrapUpAdvisory(turn:)`. The run itself still ends only on task_done or
/// the budget — the detector changes what the model is TOLD, which is what
/// breaks the loop without stealing the model's last move.
public struct MerlinStopAuthority: Sendable {
    /// Identical consecutive failing signatures that trigger wrap-up.
    public let repeatThreshold: Int

    public init(repeatThreshold: Int = 3) {
        self.repeatThreshold = max(2, repeatThreshold)
    }

    // MARK: - Signatures

    /// One executed call's fingerprint: tool + normalized args + outcome
    /// class. Equatable so consecutive-run detection is an equality check.
    public struct ResultSignature: Equatable, Sendable, CustomStringConvertible {
        public let tool: String
        public let normalizedArguments: String
        public let outcomeClass: OutcomeClass

        public enum OutcomeClass: String, Sendable {
            /// The call succeeded (or at least did not fail).
            case success
            /// The call failed; the next digest shows the failure.
            case failure
            /// The result was rejected by the M4 guardian.
            case guardianRejection
        }

        public init(tool: String, normalizedArguments: String, outcomeClass: OutcomeClass) {
            self.tool = tool
            self.normalizedArguments = normalizedArguments
            self.outcomeClass = outcomeClass
        }

        public var description: String { "\(tool)|\(normalizedArguments)|\(outcomeClass.rawValue)" }
    }

    /// Normalizes a call's argument JSON into the signature's argument
    /// component: keys sorted, whitespace collapsed, values stringified.
    /// Deterministic, so the same call in different key orders still
    /// matches (a small model re-serializing `{"a":1,"b":2}` as
    /// `{ "b" : 2, "a" : 1 }` must count as the same failing call).
    public static func normalizedArguments(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Unparsable arguments normalize to their collapsed raw text:
            // two identical malformed calls are still the same mistake.
            return argumentsJSON
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return Self.renderNormalized(object)
    }

    /// Renders decoded JSON deterministically: keys sorted recursively,
    /// arrays in order, numbers through their standard description.
    static func renderNormalized(_ value: Any) -> String {
        switch value {
        case let dictionary as [String: Any]:
            let rendered = dictionary.keys.sorted().map { key in
                "\(key):\(Self.renderNormalized(dictionary[key] ?? NSNull()))"
            }
            return "{" + rendered.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + array.map(Self.renderNormalized).joined(separator: ",") + "]"
        case let number as NSNumber:
            return number.stringValue
        case let boolean as Bool:
            return boolean ? "true" : "false"
        case let string as String:
            return "\"\(string)\""
        default:
            return String(describing: value)
        }
    }

    /// Builds the signature for one executed call, given the model-facing
    /// result text (or the thrown error's description).
    public static func signature(tool: String, argumentsJSON: String,
                                 result: String, isError: Bool) -> ResultSignature {
        let collapsed = result.lowercased()
        let outcome: ResultSignature.OutcomeClass
        if isError {
            outcome = .failure
        } else if collapsed.contains("rejected by guardian") {
            outcome = .guardianRejection
        } else {
            outcome = .success
        }
        return ResultSignature(tool: tool,
                               normalizedArguments: normalizedArguments(argumentsJSON),
                               outcomeClass: outcome)
    }

    // MARK: - Streak detection

    /// The repeating-signature streak counter. State is explicit and
    /// append-driven: the kernel records one observation per executed call
    /// and asks for the verdict.
    public struct ProgressTracker: Sendable {
        /// The run's consecutive-identical-failure streak: nil when the last
        /// observation was not a failure-class signature.
        private(set) var streak: (signature: ResultSignature, length: Int)?
        /// Turn at which wrap-up was declared (advisory fires once per
        /// declaration; a *new* streak may re-declare later).
        private(set) var lastWrapUpTurn: Int?
        /// The wrap-up instruction currently in force, for `wrapUpAdvisory`.
        private(set) var activeWrapUpInstruction: String?

        public let authority: MerlinStopAuthority

        public init(authority: MerlinStopAuthority = MerlinStopAuthority()) {
            self.authority = authority
        }

        /// Records one executed call and returns the wrap-up decision.
        /// Success-class signatures reset the streak (real progress);
        /// failure/guardian classes accumulate it.
        public mutating func record(_ signature: ResultSignature, turn: Int) -> MerlinStopAuthority.Verdict {
            let isFailureClass = signature.outcomeClass != .success
            if isFailureClass, let current = streak,
               current.signature == signature {
                streak = (signature, current.length + 1)
            } else if isFailureClass {
                streak = (signature, 1)
            } else {
                streak = nil
                activeWrapUpInstruction = nil
            }

            guard let streak, streak.length >= authority.repeatThreshold else {
                return .none
            }
            let instruction = authority.wrapUpInstruction(signature: streak.signature)
            // The advisory fires when the threshold is first crossed, and
            // again on every further identical repeat (the model ignored it
            // once; say it again, louder, in the digest).
            if lastWrapUpTurn != turn || streak.length == authority.repeatThreshold {
                lastWrapUpTurn = turn
                activeWrapUpInstruction = instruction
                return .wrapUp(instruction: instruction)
            }
            return .none
        }

        /// Whether the run is currently inside a declared wrap-up (the
        /// kernel renders this into the spine prompt).
        public var isWrappingUp: Bool { activeWrapUpInstruction != nil }

        /// The advisory line for the current turn's spine prompt, or nil.
        /// Rendered by the kernel through `wrapUpAdvisory(turn:)`.
        public func wrapUpAdvisory(turn: Int) -> String? {
            guard let instruction = activeWrapUpInstruction else { return nil }
            return "STOP AUTHORITY: \(instruction)"
        }
    }

    /// The detector's verdict after one observation.
    public enum Verdict: Equatable, Sendable {
        case none
        /// Threshold crossed: inject `instruction` as a blocker.
        case wrapUp(instruction: String)
    }

    /// The wrap-up instruction for a stuck signature. Actionable by
    /// contract: it names the repeated call and offers exactly two exits.
    public func wrapUpInstruction(signature: ResultSignature) -> String {
        let repeated = "\(signature.tool) with arguments \(signature.normalizedArguments)"
        return "no progress detected; either change approach or file task_done with what exists"
            + " (you have now repeated \(repeated) \(repeatThreshold) times without success — do not issue it again)"
    }
}
