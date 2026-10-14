// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Structured view model for a plain-text decision card. `parse` accepts
/// exactly the text `LayaDecideService.cardText` ships — the chat renders
/// the model as a rich card and falls back to the raw text when `parse`
/// returns nil. Pure string work, so a check can round-trip the shipped
/// shape without a network.
struct LayaDecisionCardModel: Equatable {
    struct Option: Equatable, Identifiable {
        let label: String
        /// 0…1
        let probability: Double
        var id: String { label }
    }

    struct Question: Equatable, Identifiable {
        let key: String
        let instructions: String
        /// The summary line after the key, e.g. "clinical trial (82%)",
        /// "YES (91%)" or "score 64".
        let answer: String
        /// Choice probabilities in card order (highest first).
        let options: [Option]
        var id: String { key }

        /// YES/NO with its probability when the answer is a noul verdict.
        var yesNo: (isYes: Bool, probability: Double)? {
            guard answer.hasSuffix("%)"), let open = answer.firstIndex(of: "(") else { return nil }
            let head = answer[..<open].trimmingCharacters(in: .whitespaces)
            guard head == "YES" || head == "NO",
                  let pct = Double(String(answer[answer.index(after: open)...].dropLast(2))) else { return nil }
            return (head == "YES", pct / 100)
        }

        /// The anchored score when the answer is one.
        var score: Int? {
            guard answer.hasPrefix("score ") else { return nil }
            return Int(answer.dropFirst("score ".count))
        }

        /// What the compact chat card shows as the verdict line.
        var headline: String {
            if let yesNo { return yesNo.isYes ? "YES" : "NO" }
            if let score { return String(score) }
            return answer
        }
    }

    let setName: String
    let questions: [Question]

    /// nil when `text` is not a decision card — the caller then shows the
    /// text as-is (the plain-text fallback).
    static func parse(_ text: String) -> LayaDecisionCardModel? {
        var lines = text.components(separatedBy: "\n")[...]
        guard let header = lines.first, header.hasPrefix(LayaDecideService.cardHeader) else { return nil }
        let setName = String(header.dropFirst(LayaDecideService.cardHeader.count))

        var questions: [Question] = []
        var instructions: String?
        var key: String?
        var answer: String?
        var options: [Option] = []

        func finalize() {
            // Guard bindings are named: `guard let instructions` would shadow
            // the outer optionals with non-optional lets inside this body,
            // making the resets below a compile error.
            guard let gotInstructions = instructions, let gotKey = key else { return }
            questions.append(Question(key: gotKey, instructions: gotInstructions,
                                      answer: answer ?? "", options: options))
            instructions = nil; key = nil; answer = nil; options = []
        }

        for line in lines.dropFirst() {
            if line.hasPrefix("Q: ") {
                finalize()
                instructions = String(line.dropFirst(3))
            } else if line.hasPrefix("   → ") {
                let rest = String(line.dropFirst(5))
                if let separator = rest.range(of: " → ") {
                    key = String(rest[..<separator.lowerBound])
                    answer = String(rest[separator.upperBound...])
                } else {
                    key = rest
                    answer = ""
                }
            } else if line.hasPrefix("   "), line.contains("%") {
                // Probability row: "   <label padded to ≥24>  82.0% ███"
                let body = line.dropFirst(3)
                guard let percentMark = body.firstIndex(of: "%"),
                      let numberStart = body[..<percentMark].range(of: #"[0-9.]+$"#,
                                                                   options: .regularExpression)?.lowerBound,
                      let pct = Double(String(body[numberStart..<percentMark])) else { continue }
                let label = String(body[..<numberStart]).trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { options.append(Option(label: label, probability: pct / 100)) }
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                finalize()
            }
        }
        finalize()
        return LayaDecisionCardModel(setName: setName, questions: questions)
    }
}

// MARK: - Shared card pieces

/// Identifiable (key, question) pair so SwiftUI can iterate a set's
/// questions in deterministic id order.
struct LayaKeyedQuestion: Identifiable {
    let key: String
    let question: LayaDecideService.QuestionSet.Question
    var id: String { key }

    static func list(from questions: [String: LayaDecideService.QuestionSet.Question]) -> [LayaKeyedQuestion] {
        questions.sorted { $0.key < $1.key }
            .map { LayaKeyedQuestion(key: $0.key, question: $0.value) }
    }
}

/// One labeled confidence bar: label, linear gauge, percent. `topLabel`
/// tints the winner of a choice ranking.
struct LayaProbabilityBar: View {
    let label: String
    /// 0…1
    let probability: Double
    let topLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .frame(minWidth: 120, alignment: .leading)
            LayaProbabilityGauge(probability: probability,
                                 tint: label == topLabel ? Color.appAccent : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(String(format: "%.0f", probability * 100)) percent")
    }

    init(label: String, probability: Double, topLabel: String = "") {
        self.label = label
        self.probability = probability
        self.topLabel = topLabel
    }
}

/// The gauge + percent tail shared by every bar and the yes/no badge.
struct LayaProbabilityGauge: View {
    /// 0…1
    let probability: Double
    let tint: Color

    var body: some View {
        ProgressView(value: min(max(probability, 0), 1))
            .tint(tint)
        Text(String(format: "%.1f%%", min(max(probability, 0), 1) * 100))
            .font(.system(.caption, design: .monospaced))
            .frame(width: 48, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}

/// YES/NO verdict with the probability of the stated verdict.
struct LayaYesNoBadge: View {
    let isYes: Bool
    /// Probability the verdict is the stated one, 0…1.
    let probability: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(isYes ? "YES" : "NO")
                .font(.system(.callout, design: .rounded).bold())
                .foregroundStyle(isYes ? Color.green : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 3)
                .background((isYes ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            LayaProbabilityGauge(probability: probability, tint: Color.appAccent)
        }
    }
}

/// Anchored 0–100 score with its low/middle/high anchor labels.
struct LayaScoreBar: View {
    let score: Int
    /// [low, middle, high] anchor texts; hidden when nil.
    let anchors: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(score))
                    .font(.system(.title3, design: .rounded).bold())
                Text("/ 100").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.appAccent)
                        .frame(width: proxy.size.width * CGFloat(min(max(score, 0), 100)) / 100)
                }
            }
            .frame(height: 8)
            .accessibilityLabel("Score \(score) of 100")
            if let anchors, anchors.count == 3 {
                HStack {
                    Text(anchors[0]); Spacer(); Text(anchors[1]); Spacer(); Text(anchors[2])
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// One typed answer as a native card: choice probabilities, yes/no with
/// probability, or the anchored score. The Decisions section renders it
/// straight from the typed answer; re-opened history runs render it from
/// the snapshotted answer.
struct LayaAnswerCard: View {
    let key: String
    let question: LayaDecideService.QuestionSet.Question
    let answer: LayaDecideService.Answer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.instructions)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let answer {
                switch answer.type {
                case "noul":
                    LayaYesNoBadge(isYes: (answer.noulProbability ?? 0) >= 0.5,
                                   probability: answer.noulProbability ?? 0)
                case "score":
                    LayaScoreBar(score: Int((answer.score ?? 0).rounded()),
                                 anchors: question.criteriaScore)
                default:
                    HStack(spacing: 8) {
                        Text(answer.choice ?? "—")
                            .font(.system(.callout, design: .rounded).bold())
                        Text(String(format: "%.1f%%", answer.confidence * 100))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(key)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    let ranked = answer.probabilities.sorted { $0.value > $1.value }
                        .map { LayaDecisionCardModel.Option(label: $0.key, probability: $0.value) }
                    if !ranked.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(ranked) { option in
                                LayaProbabilityBar(label: option.label, probability: option.probability,
                                                   topLabel: ranked.first?.label ?? "")
                            }
                        }
                    }
                }
            } else {
                Text("No answer for this question")
                    .font(.caption.italic()).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(WorkspaceStyle.border))
    }
}

/// Rich in-chat card for a `laya_decide` result, built from the parsed
/// plain-text card. When the text does not parse, callers show the raw
/// text instead (the plain-text fallback).
struct LayaDecisionCardView: View {
    let model: LayaDecisionCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Decision card — \(model.setName)", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(model.questions) { question in
                VStack(alignment: .leading, spacing: 5) {
                    Text(question.instructions)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let yesNo = question.yesNo {
                        LayaYesNoBadge(isYes: yesNo.isYes, probability: yesNo.probability)
                    } else if let score = question.score {
                        LayaScoreBar(score: score, anchors: nil)
                    } else {
                        Text(question.answer)
                            .font(.system(.callout, design: .rounded).bold())
                        if !question.options.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(question.options) { option in
                                    LayaProbabilityBar(label: option.label,
                                                       probability: option.probability,
                                                       topLabel: question.options.first?.label ?? "")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                if question.id != model.questions.last?.id { Divider() }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
