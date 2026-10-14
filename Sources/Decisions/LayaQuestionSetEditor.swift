// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Create, edit, duplicate and delete question sets under
/// `…/Kestrel/laya-questions` — the same store the `laya_decide` tool
/// reads. Editing works on a draft; Save writes it through
/// `LayaDecideService.saveSet` (and removes the old file on rename).
struct LayaQuestionSetsSheet: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedSetName: String
    let onChange: () -> Void

    @State private var sets: [LayaDecideService.QuestionSet] = []
    @State private var draft: LayaEditableSet?
    @State private var confirmingDelete: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(loc.t("Conjuntos de preguntas", "Question sets"),
                      systemImage: "checklist")
                    .font(.title3.bold())
                Spacer()
                Button {
                    draft = LayaEditableSet.draft()
                } label: {
                    Label(loc.t("Nuevo conjunto", "New set"), systemImage: "plus")
                }
                .glassButton()
                Button(loc.t("Listo", "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassButton(prominent: true)
            }
            .padding(16)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Set list
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sets, id: \.name) { set in
                            setRow(set)
                        }
                        if sets.isEmpty {
                            Text(loc.t("Sin conjuntos todavía — crea uno.",
                                       "No sets yet — create one."))
                                .font(.caption).foregroundStyle(.tertiary)
                                .padding(10)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 230)
                Divider()

                // Editor
                if let draft {
                    LayaSetEditor(draft: draft) { saved in
                        apply(saved)
                    }
                    .id(draft.id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist")
                            .font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text(loc.t("Selecciona un conjunto para editarlo, o crea uno nuevo.",
                                   "Select a set to edit it, or create a new one."))
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 470)
        .background(WorkspaceStyle.canvas)
        .onAppear { reload() }
        .confirmationDialog(
            loc.t("¿Eliminar el conjunto “%@”? Su archivo se borra de laya-questions.",
                  "Delete set “%@”? Its file is removed from laya-questions."),
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(loc.t("Eliminar conjunto", "Delete set"), role: .destructive) {
                if let name = confirmingDelete {
                    LayaDecideService.deleteSet(named: name)
                    if selectedSetName == name { selectedSetName = "" }
                    confirmingDelete = nil
                    reload()
                    onChange()
                }
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { confirmingDelete = nil }
        }
    }

    private func setRow(_ set: LayaDecideService.QuestionSet) -> some View {
        let isDraft = draft?.originalName == set.name
        return HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(isDraft ? Color.appAccent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name).font(.system(size: 13, weight: isDraft ? .semibold : .regular))
                    .lineLimit(1)
                Text(loc.t("%@ preguntas", "%@ questions", "\(set.questions.count)"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(isDraft ? Color.appAccent.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { draft = LayaEditableSet(set: set) }
        .contextMenu {
            Button(loc.t("Duplicar", "Duplicate")) {
                var copy = LayaEditableSet(set: set)
                copy.name = uniqueName(copy.name)
                copy.originalName = nil
                draft = copy
            }
            Button(loc.t("Eliminar…", "Delete…"), role: .destructive) {
                confirmingDelete = set.name
            }
        }
    }

    /// Save: write the draft, drop the old file on rename, keep selection
    /// pointing at the saved name.
    private func apply(_ saved: LayaEditableSet) {
        if let original = saved.originalName, original != saved.name {
            LayaDecideService.deleteSet(named: original)
        }
        try? LayaDecideService.saveSet(saved.questionSet())
        selectedSetName = saved.name
        reload()
        onChange()
        draft = LayaEditableSet(set: saved.questionSet())
    }

    private func uniqueName(_ base: String) -> String {
        var candidate = "\(base) copy"
        var i = 2
        while sets.contains(where: { $0.name == candidate }) {
            candidate = "\(base) copy \(i)"
            i += 1
        }
        return candidate
    }

    private func reload() {
        sets = LayaDecideService.loadSets()
    }
}

// MARK: - Editable draft

/// Working copy of a set while it is being edited.
struct LayaEditableSet: Identifiable {
    let id = UUID()
    /// The stored set this draft came from; nil for a brand-new set.
    var originalName: String?
    var name: String
    var questions: [LayaEditableQuestion]

    init(set: LayaDecideService.QuestionSet) {
        originalName = set.name
        name = set.name
        questions = set.questions
            .sorted { $0.key < $1.key }
            .map { LayaEditableQuestion(key: $0.key, question: $0.value) }
    }

    /// The struct declares `init(set:)`, which suppresses the memberwise
    /// initializer — this restores it for the brand-new-draft call sites.
    init(originalName: String?, name: String, questions: [LayaEditableQuestion]) {
        self.originalName = originalName
        self.name = name
        self.questions = questions
    }

    static func draft() -> LayaEditableSet {
        LayaEditableSet(originalName: nil, name: "", questions: [LayaEditableQuestion.empty()])
    }

    /// The stored form: keys de-duplicated, blank questions dropped.
    func questionSet() -> LayaDecideService.QuestionSet {
        var out: [String: LayaDecideService.QuestionSet.Question] = [:]
        var used: Set<String> = []
        for question in questions
        where question.key.nilIfBlank != nil && question.instructions.nilIfBlank != nil {
            let base = question.key.trimmingCharacters(in: .whitespaces)
            var key = base
            var suffix = 2
            while used.contains(key) { key = "\(base)-\(suffix)"; suffix += 1 }
            used.insert(key)
            out[key] = question.question()
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return LayaDecideService.QuestionSet(name: trimmed.isEmpty ? "Untitled set" : trimmed,
                                             questions: out)
    }
}

/// Working copy of one question.
struct LayaEditableQuestion: Identifiable {
    let id = UUID()
    var key: String
    /// "choice" | "noul" | "score"
    var type: String
    var instructions: String
    var choiceCriteria: [Criterion]
    var scoreAnchors: [String]

    struct Criterion: Identifiable {
        let id = UUID()
        var label: String
        var detail: String
    }

    init(key: String, question: LayaDecideService.QuestionSet.Question) {
        self.key = key
        self.type = question.type
        self.instructions = question.instructions
        self.choiceCriteria = (question.criteriaChoice ?? [:])
            .sorted { $0.key < $1.key }
            .map { Criterion(label: $0.key, detail: $0.value) }
        self.scoreAnchors = question.criteriaScore ?? []
    }

    /// Same memberwise-initializer restore as LayaEditableSet above.
    init(key: String, type: String, instructions: String,
         choiceCriteria: [Criterion], scoreAnchors: [String]) {
        self.key = key
        self.type = type
        self.instructions = instructions
        self.choiceCriteria = choiceCriteria
        self.scoreAnchors = scoreAnchors
    }

    static func empty() -> LayaEditableQuestion {
        LayaEditableQuestion(key: "", type: "choice", instructions: "",
                             choiceCriteria: [Criterion(label: "", detail: "")], scoreAnchors: [])
    }

    func question() -> LayaDecideService.QuestionSet.Question {
        var criteriaChoice: [String: String]?
        var criteriaScore: [String]?
        if type == "choice" {
            let map = Dictionary(choiceCriteria
                .map { ($0.label.trimmingCharacters(in: .whitespaces), $0.detail) }
                .filter { !$0.0.isEmpty }, uniquingKeysWith: { _, last in last })
            criteriaChoice = map.isEmpty ? nil : map
        } else if type == "score" {
            let anchors = scoreAnchors.map { $0.trimmingCharacters(in: .whitespaces) }
            criteriaScore = anchors.allSatisfy { $0.nilIfBlank == nil } ? nil : anchors
        }
        return LayaDecideService.QuestionSet.Question(type: type,
                                                      instructions: instructions.trimmingCharacters(in: .whitespaces),
                                                      criteriaChoice: criteriaChoice,
                                                      criteriaScore: criteriaScore)
    }
}

// MARK: - Editor

private struct LayaSetEditor: View {
    @EnvironmentObject private var loc: Localizer
    @State private var draft: LayaEditableSet
    let onSave: (LayaEditableSet) -> Void

    init(draft: LayaEditableSet, onSave: @escaping (LayaEditableSet) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField(loc.t("Nombre del conjunto", "Set name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        onSave(draft)
                    } label: {
                        Label(loc.t("Guardar", "Save"), systemImage: "square.and.arrow.down")
                    }
                    .glassButton(prominent: true)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.questions.filter {
                                  $0.key.nilIfBlank != nil && $0.instructions.nilIfBlank != nil
                              }.isEmpty)
                }

                ForEach($draft.questions) { $question in
                    LayaQuestionEditor(question: $question)
                        .padding(12)
                        .background(WorkspaceStyle.inset,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(WorkspaceStyle.border))
                }

                Button {
                    draft.questions.append(LayaEditableQuestion.empty())
                } label: {
                    Label(loc.t("Añadir pregunta", "Add question"), systemImage: "plus")
                }
                .glassButton()
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LayaQuestionEditor: View {
    @EnvironmentObject private var loc: Localizer
    @Binding var question: LayaEditableQuestion

    private let types = ["choice", "noul", "score"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField(loc.t("id (p. ej. study_type)", "id (e.g. study_type)"), text: $question.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Picker(loc.t("Tipo", "Type"), selection: $question.type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            TextField(loc.t("Instrucciones de la pregunta", "Question instructions"),
                      text: $question.instructions)
                .textFieldStyle(.roundedBorder)

            switch question.type {
            case "choice":
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("Etiquetas y qué pertenece en cada una",
                               "Labels and what belongs in each"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ForEach($question.choiceCriteria) { $criterion in
                        HStack(spacing: 8) {
                            TextField(loc.t("etiqueta", "label"), text: $criterion.label)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            TextField(loc.t("qué pertenece en esta etiqueta", "what belongs in this label"),
                                      text: $criterion.detail)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                question.choiceCriteria.removeAll { $0.id == criterion.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help(loc.t("Quitar etiqueta", "Remove label"))
                        }
                    }
                    Button {
                        question.choiceCriteria.append(.init(label: "", detail: ""))
                    } label: {
                        Label(loc.t("Añadir etiqueta", "Add label"), systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            case "score":
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("Anclas (bajo · medio · alto)", "Anchors (low · middle · high)"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField(loc.t("bajo", "low"), text: anchor(0))
                        TextField(loc.t("medio", "middle"), text: anchor(1))
                        TextField(loc.t("alto", "high"), text: anchor(2))
                    }
                }
            default:
                Text(loc.t("Sí/no con probabilidad — no necesita criterios.",
                           "Yes/no with probability — no criteria needed."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func anchor(_ index: Int) -> Binding<String> {
        Binding(
            get: { question.scoreAnchors.indices.contains(index) ? question.scoreAnchors[index] : "" },
            set: { value in
                while question.scoreAnchors.count < 3 { question.scoreAnchors.append("") }
                question.scoreAnchors[index] = value
            })
    }
}
