// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Laya, integrated: the System-1 decision model (ggml-org, Apache-2.0)
/// served by the app's "Laya Decisions" server card on port 8098 through
/// llama-server's `/v1/systemone` endpoint. Laya does not generate text —
/// it scores options: typed choice with per-option probabilities, yes/no
/// (noul) with probability, and anchored scores, at ~33 ms per question.
/// That makes it the fast decision core of the chat stack: the agent calls
/// `laya_decide` for classification, gating and verification on documents
/// instead of spending the big model's tokens and seconds on them.
enum LayaDecideService {
    static let toolName = "laya_decide"
    static let defaultPort = 8098

    // MARK: - Question sets

    /// A named set of questions. Stored as JSON under
    /// `…/Kestrel/laya-questions/<name>.json`; the built-in medical triage
    /// set is seeded on first use and can be edited like any other.
    struct QuestionSet: Codable, Equatable {
        var name: String
        var questions: [String: Question]

        struct Question: Codable, Equatable {
            var type: String                 // "choice" | "noul" | "score"
            var instructions: String
            /// "choice" → label → what belongs in the bucket.
            var criteriaChoice: [String: String]?
            /// "score" → [low anchor, middle, high anchor].
            var criteriaScore: [String]?

            /// Exact wire shape /v1/systemone expects (verified against the
            /// reference laya CLI): type, instructions, criteria.
            func wireJSON() -> [String: Any] {
                var out: [String: Any] = ["type": type, "instructions": instructions]
                if let c = criteriaChoice { out["criteria"] = c }
                if let s = criteriaScore { out["criteria"] = s }
                return out
            }
        }
    }

    /// Question-set directory. Created and seeded on first access.
    static var setsDirectory: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Kestrel/laya-questions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The built-in medical triage set (same questions as the reference
    /// laya CLI, so CLI and chat answers stay identical).
    static func medicalTriageSet() -> QuestionSet {
        QuestionSet(name: "Medical Triage", questions: [
            "study_type": QuestionSet.Question(
                type: "choice",
                instructions: "What kind of study or content is this document?",
                criteriaChoice: [
                    "clinical trial": "randomized or controlled trial with intervention groups",
                    "cohort study": "follows patient groups over time, observational",
                    "case report": "one or few patients described in detail",
                    "review": "summarizes other studies, meta-analysis or review article",
                    "other": "none of the above",
                ]),
            "reports_complications": QuestionSet.Question(
                type: "noul",
                instructions: "Does this document report surgical complications or adverse outcomes?",
                criteriaChoice: nil, criteriaScore: nil),
            "clinical_relevance": QuestionSet.Question(
                type: "score",
                instructions: "How clinically relevant is this to a practicing surgeon?",
                criteriaScore: ["background interest only", "moderately useful", "directly changes practice"]),
        ])
    }

    /// All stored sets, seeded on first use. Deterministic order for UIs.
    static func loadSets() -> [QuestionSet] {
        let fm = FileManager.default
        let seedURL = setsDirectory.appendingPathComponent("Medical Triage.json")
        if !fm.fileExists(atPath: seedURL.path),
           let data = try? JSONEncoder().encode(medicalTriageSet()) {
            try? data.write(to: seedURL, options: .atomic)
        }
        let files = (try? fm.contentsOfDirectory(at: setsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? JSONDecoder().decode(QuestionSet.self, from: Data(contentsOf: $0)) }
    }

    static func set(named name: String) -> QuestionSet? {
        loadSets().first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Client

    /// Document slices tried in order when the engine rejects content —
    /// same descending sizes as the reference CLI.
    static let sliceSizes = [12000, 5000, 2500, 1200, 700, 350]

    static func healthURL(port: Int = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    static func systemOneURL(port: Int = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)/v1/systemone")!
    }

    /// One decision pass: strips fenced code blocks, then posts
    /// progressively smaller slices until the engine accepts one.
    /// Throws `LayaError` with operator-readable guidance.
    static func decide(document: String,
                       questions: [String: QuestionSet.Question],
                       port: Int = defaultPort) async throws -> [String: Answer] {
        let clean = document.replacingOccurrences(
            of: "```(?s:.*?)```",
            with: " ",
            options: .regularExpression)
        var lastError: Error?
        for size in sliceSizes {
            let slice = String(clean.trimmingCharacters(in: .whitespacesAndNewlines).prefix(size))
            guard !slice.isEmpty else { break }
            let body = try JSONSerialization.data(withJSONObject: [
                "state": slice,
                "questions": questions.mapValues { $0.wireJSON() },
            ])
            var req = URLRequest(url: systemOneURL(port: port))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            req.httpBody = body
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    lastError = LayaError.engineRejected(status: http.statusCode)
                    continue
                }
                return try parseAnswers(data)
            } catch let error as LayaError {
                throw error
            } catch {
                lastError = LayaError.unreachable(underlying: error)
                throw LayaError.unreachable(underlying: error)
            }
        }
        throw lastError ?? LayaError.emptyDocument
    }

    // MARK: - Answers

    struct Answer: Equatable {
        let type: String
        let choice: String?
        let confidence: Double
        let probabilities: [String: Double]
        let noulProbability: Double?
        let score: Double?

        /// One readable line per question, e.g.
        /// `study_type → clinical trial (82%)` or `reports_complications → YES (91%)`.
        func summaryLine(key: String, instructions: String) -> String {
            switch type {
            case "choice":
                let pct = Int((confidence * 100).rounded())
                return "\(key) → \(choice ?? "?") (\(pct)%)"
            case "noul":
                let p = noulProbability ?? 0
                return "\(key) → \(p >= 0.5 ? "YES" : "NO") (\(Int((p * 100).rounded()))%)"
            case "score":
                return "\(key) → score \(Int(score ?? 0))"
            default:
                return key
            }
        }
    }

    static func parseAnswers(_ data: Data) throws -> [String: Answer] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: [String: Any]] else {
            throw LayaError.malformedResponse
        }
        var out: [String: Answer] = [:]
        for (key, raw) in answers {
            out[key] = Answer(
                type: raw["type"] as? String ?? "choice",
                choice: raw["choice"] as? String,
                confidence: raw["confidence"] as? Double ?? 0,
                probabilities: raw["probabilities"] as? [String: Double] ?? [:],
                noulProbability: raw["noul"] as? Double,
                score: raw["score"] as? Double)
        }
        return out
    }

    enum LayaError: LocalizedError {
        case engineDown
        case engineRejected(status: Int)
        case unreachable(underlying: Error)
        case malformedResponse
        case emptyDocument

        var errorDescription: String? {
            switch self {
            case .engineDown:
                return "Laya engine is not running. Start it yourself: Kestrel → Servers tab → 'Laya Decisions' card → Start. (Nothing starts in the background.)"
            case .engineRejected(let status):
                return "Laya engine rejected this document (HTTP \(status)) after all retry sizes."
            case .unreachable:
                return "Laya engine could not be reached on port \(LayaDecideService.defaultPort)."
            case .malformedResponse:
                return "Laya engine returned an unrecognized answer format."
            case .emptyDocument:
                return "The document is empty — nothing to decide on."
            }
        }
    }

    // MARK: - Agent tool

    static let tool: BuiltinToolInfo = BuiltinToolInfo(
        displayName: "Laya decisions",
        name: toolName,
        writesData: false,
        definition: [
            "type": "function",
            "function": [
                "name": toolName,
                "description": "Run the Laya System-1 decision model over a document: typed answers at ~33 ms per question — choice with per-option probabilities, yes/no with probability, anchored score. Use it for classification, triage, filtering and verification instead of reading whole documents yourself. The document can be a file path or inline text. Question sets: 'Medical Triage' (default) or any set stored in Kestrel's laya-questions folder; pass raw questions JSON to run your own ad-hoc set.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "document_path": [
                            "type": "string",
                            "description": "Absolute path of the document to decide on. Optional if text is given."
                        ],
                        "text": [
                            "type": "string",
                            "description": "Inline document text. Optional if document_path is given."
                        ],
                        "question_set": [
                            "type": "string",
                            "description": "Name of a stored question set (default: 'Medical Triage')."
                        ],
                        "questions": [
                            "type": "object",
                            "description": "Ad-hoc questions keyed by id: {key: {type: 'choice'|'noul'|'score', instructions: '…', criteria: …}} — criteria is {label: description} for choice, [low, mid, high] for score."
                        ]
                    ]
                ]
            ]
        ])

    /// Tool execution: read the document, resolve questions, run Laya,
    /// format a decision card. Every failure states exactly what the
    /// operator should do — no silent empties.
    static func execute(arguments: [String: Any]) async -> ToolExecutionResult {
        let path = arguments["document_path"] as? String
        let inline = (arguments["text"] as? String)?.nilIfBlank
        var document = inline ?? ""
        if let path {
            guard FileManager.default.fileExists(atPath: path) else {
                return ToolExecutionResult(content: "File not found: \(path)", isError: true)
            }
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                document = contents
            } else {
                return ToolExecutionResult(content: "Could not read file as text: \(path)", isError: true)
            }
        }
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionResult(content: "No document: give document_path or text.", isError: true)
        }

        var questions: [String: QuestionSet.Question]? = nil
        var setName = arguments["question_set"] as? String ?? "Medical Triage"
        if let raw = arguments["questions"] as? [String: Any] {
            // Re-encode through the wire shape so both ad-hoc and stored
            // sets travel the same path.
            if let data = try? JSONSerialization.data(withJSONObject: raw),
               let decoded = try? JSONDecoder().decode([String: QuestionSet.Question].self, from: data) {
                questions = decoded
                setName = "ad-hoc"
            }
        }
        if questions == nil {
            guard let set = set(named: setName) else {
                let available = loadSets().map { $0.name }.joined(separator: ", ")
                return ToolExecutionResult(
                    content: "Question set '\(setName)' not found. Stored sets: \(available). Pass questions JSON for an ad-hoc set.",
                    isError: true)
            }
            questions = set.questions
            setName = set.name
        }

        // Health first: a clear start-it-yourself message beats a timeout.
        var health = URLRequest(url: healthURL())
        health.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: health)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return ToolExecutionResult(content: LayaError.engineDown.localizedDescription, isError: true)
            }
        } catch {
            return ToolExecutionResult(content: LayaError.engineDown.localizedDescription, isError: true)
        }

        do {
            let answers = try await decide(document: document, questions: questions!)
            let ordered = questions!.keys.sorted()
            var lines = ["Laya decision card — set: \(setName)", ""]
            for key in ordered {
                let q = questions![key]!
                let a = answers[key]
                lines.append("Q: \(q.instructions)")
                lines.append("   → \(a?.summaryLine(key: key, instructions: q.instructions) ?? "no answer")")
                if let a, a.type == "choice", !a.probabilities.isEmpty {
                    let ranked = a.probabilities.sorted { $0.value > $1.value }
                    for (label, p) in ranked {
                        let bar = String(repeating: "█", count: max(0, min(20, Int(p * 20))))
                        let padded = label.padding(toLength: 24, withPad: " ", startingAt: 0)
                        lines.append("   \(padded) \(String(format: "%5.1f%%", p * 100)) \(bar)")
                    }
                }
                lines.append("")
            }
            return ToolExecutionResult(content: lines.joined(separator: "\n"), isError: false)
        } catch {
            return ToolExecutionResult(content: (error as? LayaError)?.errorDescription
                ?? LayaError.malformedResponse.localizedDescription, isError: true)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
