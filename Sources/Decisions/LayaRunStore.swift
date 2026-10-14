// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Run history for the Decisions tab: every completed decision pass stored
/// as one JSON file under `…/Kestrel/laya-runs`, plus the CSV/JSON export
/// builders for single runs, the whole history and batch aggregations.
/// Pure Foundation — no UI, no network — so the round-trip and the export
/// shapes are checkable.
enum LayaRunStore {
    /// One completed decision pass. The full question set is snapshotted so
    /// history stays readable (instructions, anchors, option labels) after
    /// the set is edited or deleted.
    struct Run: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// File name or "Pasted text".
        let documentName: String
        /// "file" | "paste".
        let documentSource: String
        let setName: String
        let questionSet: LayaDecideService.QuestionSet
        let answers: [String: LayaDecideService.Answer]
    }

    static var runsDirectory: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Kestrel/laya-runs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One encoder everywhere a run is written: readable, sorted, ISO-dated.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func save(_ run: Run) {
        if let data = try? encoder().encode(run) {
            try? data.write(to: runsDirectory.appendingPathComponent("\(run.id.uuidString).json"),
                            options: .atomic)
        }
    }

    /// Newest first — the order the history list shows.
    static func loadRuns() -> [Run] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder().decode(Run.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    @discardableResult
    static func deleteRun(id: UUID) -> Bool {
        let url = runsDirectory.appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }

    // MARK: - Row shaping

    /// The `(answer, confidence)` pair every export surface agrees on:
    /// noul → YES/NO with its probability, score → the integer with no
    /// probability to report, choice → the picked label with its confidence.
    static func answerFields(_ answer: LayaDecideService.Answer?) -> (text: String, confidence: String) {
        switch answer?.type {
        case "noul":
            let p = answer?.noulProbability ?? 0
            return (p >= 0.5 ? "YES" : "NO", String(format: "%.4f", p))
        case "score":
            return ("\(Int((answer?.score ?? 0).rounded()))", "")
        default:
            return (answer?.choice ?? "", String(format: "%.4f", answer?.confidence ?? 0))
        }
    }

    /// The question columns every export lists, in deterministic id order.
    static func questionKeys(of runs: [Run]) -> [String] {
        var keys = Set<String>()
        for run in runs { keys.formUnion(run.questionSet.questions.keys) }
        return keys.sorted()
    }

    // MARK: - Single-run export

    private static let csvHeader = "document,set,date,question_id,question_text,type,answer,confidence"

    /// CSV: one header plus one row per question, sorted by question id —
    /// the shape spreadsheets and audit tooling expect.
    static func csv(for run: Run) -> String {
        ([csvHeader] + csvRows(for: run)).joined(separator: "\n") + "\n"
    }

    private static func csvRows(for run: Run) -> [String] {
        run.questionSet.questions.keys.sorted().map { key in
            let question = run.questionSet.questions[key]
            let answer = run.answers[key]
            let type = answer?.type ?? question?.type ?? ""
            let fields = answerFields(answer)
            return [run.documentName, run.setName,
                    run.date.formatted(.iso8601),
                    key, question?.instructions ?? "", type,
                    fields.text, fields.confidence]
                .map(csvField).joined(separator: ",")
        }
    }

    /// CSV for the whole history: one header plus one row per
    /// (run × question), runs in history order (newest first).
    static func historyCSV(_ runs: [Run]) -> String {
        ([csvHeader] + runs.flatMap(csvRows(for:))).joined(separator: "\n") + "\n"
    }

    /// Pretty, sorted, ISO-dated JSON — the same records the history
    /// stores, in the shape a person can read and diff.
    static func jsonData(for run: Run) throws -> Data {
        try encoder().encode(run)
    }

    /// The whole history as a JSON array, newest first.
    static func historyJSONData(_ runs: [Run]) throws -> Data {
        try encoder().encode(runs)
    }

    // MARK: - Batch aggregation

    /// One batch pass over N documents: one row per document, successes
    /// carrying the answers, failures carrying the operator-readable error
    /// instead of aborting the batch.
    struct Batch: Codable, Equatable {
        let id: UUID
        let date: Date
        let setName: String
        let questionSet: LayaDecideService.QuestionSet
        var rows: [Row]

        struct Row: Codable, Equatable, Identifiable {
            let id: UUID
            let documentName: String
            let error: String?
            let answers: [String: LayaDecideService.Answer]
        }
    }

    /// CSV for a batch: one row per document, an answer and a confidence
    /// column per question — the results table's export twin.
    static func csv(for batch: Batch) -> String {
        let keys = batch.questionSet.questions.keys.sorted()
        var header = ["document", "status"]
        for key in keys {
            header.append(key)
            header.append("\(key) confidence")
        }
        var lines = [header.map(csvField).joined(separator: ",")]
        for row in batch.rows {
            var fields = [row.documentName, row.error == nil ? "ok" : "failed"]
            for key in keys {
                let shaped = answerFields(row.answers[key])
                fields.append(row.error == nil ? shaped.text : "")
                fields.append(row.error == nil ? shaped.confidence : "")
            }
            lines.append(fields.map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func jsonData(for batch: Batch) throws -> Data {
        try encoder().encode(batch)
    }

    /// RFC-4180 quoting: only fields that need it are quoted.
    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
