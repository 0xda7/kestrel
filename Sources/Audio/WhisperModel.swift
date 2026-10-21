// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct WhisperModel: Identifiable, Hashable {
    enum Tier {
        case fast, recommended, maximum, advanced
    }

    let id: String
    let name: String
    let sizeMB: Int
    let tier: Tier
    let detailES: String
    let detailEN: String

    var fileName: String { "ggml-\(id).bin" }
    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
    }

    static let catalog: [WhisperModel] = [
        .init(id: "small", name: "Small", sizeMB: 466, tier: .fast,
              detailES: "Rápido · multilingüe", detailEN: "Fast · multilingual"),
        .init(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo Q5", sizeMB: 547, tier: .advanced,
              detailES: "Compacto · precisión muy buena", detailEN: "Compact · very good accuracy"),
        .init(id: "large-v3-turbo", name: "Large v3 Turbo", sizeMB: 1_536, tier: .recommended,
              detailES: "Mejor equilibrio · multilingüe", detailEN: "Best balance · multilingual"),
        .init(id: "large-v3", name: "Large v3", sizeMB: 2_944, tier: .maximum,
              detailES: "Máxima precisión · multilingüe", detailEN: "Maximum accuracy · multilingual"),
        .init(id: "base", name: "Base", sizeMB: 142, tier: .advanced,
              detailES: "Dictado ligero · multilingüe", detailEN: "Light dictation · multilingual")
    ]

    static let recommendedID = "large-v3-turbo"

    static func model(id: String) -> WhisperModel {
        catalog.first { $0.id == id }
            ?? catalog.first { $0.id == recommendedID }
            ?? catalog[0]
    }

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }
}

enum WhisperTranscript {
    nonisolated static func normalized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Typed failure of the timestamped parse (census W8 WhisperModel:59,
    /// T2-3 chunk B): the payload is not JSON, not an object, or carries
    /// neither "segments" nor "transcription" — no timestamped transcript
    /// exists in it at all.
    enum ParseError: Error, LocalizedError {
        case unparseable

        var errorDescription: String? {
            "the Whisper output is not a readable transcript payload"
        }
    }

    /// Throwing form (census W8 WhisperModel:59, T2-3 chunk B): distinguishes
    /// "parsed" from "unparseable" so the transcription callers can surface a
    /// failure instead of silently substituting an empty transcript.
    nonisolated static func parsedTimestamped(jsonData: Data) throws -> String {
        let root: [String: Any]?
        do {
            root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        } catch {
            root = nil
        }
        guard let root else {
            throw ParseError.unparseable
        }
        if let segments = root["segments"] as? [[String: Any]] {
            return segments.compactMap { segment -> String? in
                guard let text = segment["text"] as? String else { return nil }
                let cleaned = normalized(text)
                guard !cleaned.isEmpty else { return nil }
                let seconds = segment["start"] as? Double ?? 0
                return "[\(timestamp(seconds: seconds))] \(cleaned)"
            }.joined(separator: "\n")
        }
        guard let segments = root["transcription"] as? [[String: Any]] else {
            throw ParseError.unparseable
        }
        let lines = segments.compactMap { segment -> String? in
            guard let text = segment["text"] as? String else { return nil }
            let cleaned = normalized(text)
            guard !cleaned.isEmpty else { return nil }
            let timestamps = segment["timestamps"] as? [String: Any]
            let start = (timestamps?["from"] as? String)?.split(separator: ",").first.map(String.init)
                ?? "00:00:00"
            return "[\(start)] \(cleaned)"
        }
        return lines.joined(separator: "\n")
    }

    /// Optional form: behavior byte-identical to its pre-conversion shape —
    /// an unparseable payload maps to nil, which callers must surface rather
    /// than substitute "" for (census W8 WhisperModel:59).
    nonisolated static func timestamped(jsonData: Data) -> String? {
        try? parsedTimestamped(jsonData: jsonData)
    }

    private nonisolated static func timestamp(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        func twoDigits(_ value: Int) -> String {
            value < 10 ? "0\(value)" : String(value)
        }
        return "\(twoDigits(total / 3_600)):\(twoDigits((total / 60) % 60)):\(twoDigits(total % 60))"
    }
}
