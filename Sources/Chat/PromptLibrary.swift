// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI

// MARK: - Model

/// Type of a template variable, mirroring llm-space's workspace schema
/// (deer-flow/llm-space, MIT): `currentDate`, `workingDirectory` and `skills`
/// resolve automatically at apply time, `text` is filled by the user.
enum PromptVariableType: String, Codable, CaseIterable {
    case text
    case currentDate
    case workingDirectory
    case skills

    /// Decodes an unknown stored type as `text` instead of failing the whole
    /// library load — load() treats a failed decode as a corrupt file and
    /// would reseed, discarding the user's templates.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .text
    }
}

/// One variable spec on a template — llm-space's workspace variable schema
/// `{ name, type, format? }` reduced to what Kestrel renders. `format` stays
/// free-form String: it carries llm-space's date vocabulary ("readable-date",
/// "iso-date", "local-date-time"), its skills vocabulary ("markdown-list",
/// "xml"), or a raw DateFormatter pattern.
struct PromptVariableSpec: Codable, Equatable {
    var name: String
    var type: PromptVariableType = .text
    var format: String? = nil
}

/// One saved prompt template in the Prompt Space library. Templates carry
/// `{{variables}}` rendered at apply time; the body is plain text so it can
/// ride any engine's system-prompt surface (model engine, latch, pi).
struct PromptTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var body: String
    var created = Date()
    var updated = Date()
    /// Typed-variable specs (llm-space's workspace schema). Optional and
    /// defaulted so prompt-library.json saved by older builds still decodes;
    /// older builds likewise ignore the extra keys.
    var variables: [PromptVariableSpec]? = nil
    /// A/B variant bodies by key. Optional for the same reason.
    var variants: [String: String]? = nil
    /// Which variant apply uses. nil or "default" means the main body —
    /// llm-space's DEFAULT_VARIABLE_VARIANT_NAME is "default" and its desktop
    /// app "only writes the default bucket", i.e. the main body.
    var activeVariant: String? = nil

    /// The variant key that means "the main body" (llm-space convention).
    static let defaultVariantKey = "default"

    /// The body apply renders: the active variant's text when one is active,
    /// else — or when the variant is missing/empty — the main body. A
    /// dangling `activeVariant` degrades to the main body rather than an
    /// empty prompt.
    var effectiveBody: String {
        guard let key = activeVariant?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key != Self.defaultVariantKey,
              let variantBody = variants?[key], !variantBody.isEmpty else { return body }
        return variantBody
    }
}

/// The prompt-engineering library (llm-space "prompt space" convention,
/// mirrored into Kestrel): named, versioned templates with variables, stored
/// as JSON under Application Support — user data, never code constants.
enum PromptLibrary {
    static var fileURL: URL {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory,
                                                       .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Library/Application Support"
        return URL(fileURLWithPath: base + "/Kestrel/prompt-library.json")
    }

    /// Loads the library, seeding first-run defaults so the space is never
    /// empty. A missing file is the normal first-launch case and seeds; a
    /// file that EXISTS but fails to decode is treated as corrupt and
    /// reseeded; a READ failure (EIO, disk hiccup) returns the seeds in
    /// memory but does NOT overwrite the file — one bad read must never
    /// destroy every saved template.
    static func load() -> [PromptTemplate] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL) {
                if let templates = try? JSONDecoder().decode([PromptTemplate].self, from: data),
                   !templates.isEmpty {
                    return templates
                }
                // Exists, readable, undecodable: corrupt beyond repair.
            } else {
                // Exists but unreadable: keep the file, serve the seeds, and
                // let a later launch retry the read.
                return seedTemplates
            }
        }
        let seeded = seedTemplates
        save(seeded)
        return seeded
    }

    static func save(_ templates: [PromptTemplate]) {
        try? FileManager.default.createDirectory(atPath: fileURL.deletingLastPathComponent().path,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(templates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// First-run set. "Kestrel Assistant" mirrors the sidecar fallback
    /// persona so operators start by editing, not inventing.
    static let seedTemplates: [PromptTemplate] = [
        PromptTemplate(
            name: "Kestrel Assistant",
            body: "You are the Kestrel assistant, answering inside a conversation. "
                + "Reply directly as the assistant; your reply becomes the next "
                + "assistant message."),
        PromptTemplate(
            name: "Code Explainer",
            body: "You are a senior engineer explaining code to a colleague. "
                + "Walk through what the code does, then why it is written that "
                + "way, then any risks. Be concrete; quote the lines you mean. "
                + "Language: {{language}}."),
        PromptTemplate(
            name: "Summarizer",
            body: "Summarize the following as {{style}} bullets, then list open "
                + "questions the reader should still decide.\n\nContent:\n{{content}}"),
    ]

    // MARK: Variables

    /// Extracts `{{variables}}` in order of first appearance, trimmed and
    /// de-duplicated. Unmatched braces are ignored, so ordinary text (and
    /// Swift/JSON snippets containing braces) pass through untouched.
    static func variables(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var names: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let name = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// Replaces `{{variable}}` occurrences (whitespace-tolerant,
    /// case-insensitive) with their values. Variables without a value stay
    /// visible as placeholders so an incomplete form is obvious, never silent.
    static func render(_ text: String, values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        var result = text
        // Replace back-to-front so earlier NSRange offsets stay valid.
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text) else { continue }
            let key = text[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = values[key] ?? values[key.lowercased()], !value.isEmpty {
                result.replaceSubrange(matchRange, with: value)
            }
        }
        return result
    }

    // MARK: Typed variables (llm-space workspace schema)

    /// Formats a date for a `currentDate` variable. llm-space's vocabulary:
    /// "readable-date" (the default) is the medium local style — "Oct 3, 2026"
    /// — "iso-date" is `yyyy-MM-dd`, "local-date-time" adds the time. Any
    /// other non-empty string is used as a raw DateFormatter pattern.
    static func formattedDate(_ date: Date, format: String?, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let format = format?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch format.lowercased() {
        case "", "readable-date":
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        case "iso-date":
            // Fixed pattern: pin the locale so it stays ASCII `yyyy-MM-dd`.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
        case "local-date-time":
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        default:
            formatter.dateFormat = format
        }
        return formatter.string(from: date)
    }

    /// Working-directory resolution for a `workingDirectory` variable: the
    /// conversation (or its project) working directory when available, else
    /// the repo default — the process working directory, which is the repo
    /// root when Kestrel runs from a checkout (same fallback shape as
    /// RichContentBlocks.assetsDirectory).
    static func resolveWorkingDirectory(_ conversationWorkingDirectory: String?) -> String {
        let trimmed = conversationWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return FileManager.default.currentDirectoryPath
    }

    /// Upper bound on the skills embedded for a `skills` variable, per the
    /// pinned SkillsDiscovery contract (`markdownList(maxSkills: 40)`).
    static let skillsVariableMaxSkills = 40

    /// Values for the template's typed variables, keyed for render()'s
    /// case-insensitive lookup (exact spec name plus its lowercased form).
    /// Empty results (a `skills` variable with no skills found) stay out of
    /// the map so the placeholder remains visible.
    static func typedValues(for template: PromptTemplate,
                            workingDirectory: String? = nil,
                            date: Date = Date(),
                            locale: Locale = .current) -> [String: String] {
        var values: [String: String] = [:]
        for spec in template.variables ?? [] {
            let value: String
            switch spec.type {
            case .text:
                continue
            case .currentDate:
                value = formattedDate(date, format: spec.format, locale: locale)
            case .workingDirectory:
                value = resolveWorkingDirectory(workingDirectory)
            case .skills:
                value = SkillsDiscovery.markdownList(maxSkills: skillsVariableMaxSkills)
            }
            guard !value.isEmpty else { continue }
            values[spec.name] = value
            values[spec.name.lowercased()] = value
        }
        return values
    }

    /// Apply-time render, in llm-space's resolution order: typed variables
    /// resolve FIRST (so a typed value may still reference user variables),
    /// then user variables. Unmatched placeholders stay visible in both
    /// passes. For a template without typed variables this is exactly
    /// `render(text, values:)`.
    static func apply(_ text: String,
                      template: PromptTemplate,
                      values: [String: String],
                      workingDirectory: String? = nil,
                      date: Date = Date(),
                      locale: Locale = .current) -> String {
        let typed = typedValues(for: template, workingDirectory: workingDirectory,
                                date: date, locale: locale)
        return render(render(text, values: typed), values: values)
    }

    // MARK: Create with pi

    /// Template name derived from the task's first words (the "create with
    /// pi" flow): up to six words, capped at 48 characters.
    static func name(fromTask task: String) -> String {
        var name = task.split(whereSeparator: \.isWhitespace).prefix(6)
            .joined(separator: " ")
        if name.count > 48 { name = String(name.prefix(48)) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Prompt Space sheet

/// The Prompt Space (wave 1): browse the template library, fill its
/// variables, apply the render as this conversation's system prompt. Editing
/// and creating templates lives in the same sheet so the loop stays closed.
/// Wave 2 adds llm-space's typed variables, A/B variants, and pi as the
/// prompt creator.
struct PromptSpaceView: View {
    @EnvironmentObject var loc: Localizer
    /// Receives the rendered prompt; the caller decides where it lands
    /// (currently the conversation's system prompt).
    let onApply: (String) -> Void
    /// The conversation/project working directory for `workingDirectory`
    /// variables (nil falls back to the repo default at resolution time).
    var workingDirectory: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [PromptTemplate] = []
    @State private var selectedID: UUID?
    @State private var values: [String: String] = [:]
    @State private var editingBody: String = ""
    @State private var isCreating = false
    @State private var newDraft = PromptTemplate(name: "", body: "")
    @State private var isCreatingWithPi = false
    @State private var newVariantName = ""

    private var selected: PromptTemplate? {
        templates.first { $0.id == selectedID }
    }
    /// Variables of the body apply actually renders (the active variant when
    /// one is active, else the main body).
    private var selectedVariables: [String] {
        PromptLibrary.variables(in: selected?.effectiveBody ?? "")
    }
    /// Variant keys sorted, so the switcher menu is stable.
    private var variantKeys: [String] {
        (selected?.variants ?? [:]).keys.sorted()
    }
    /// The switcher's selection: "default" stands for the main body.
    private var activeVariantKey: String {
        guard let template = selected,
              let key = template.activeVariant?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key != PromptTemplate.defaultVariantKey,
              template.variants?[key] != nil else { return PromptTemplate.defaultVariantKey }
        return key
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(loc.t("Espacio de prompts", "Prompt Space"),
                      systemImage: "text.badge.star")
                    .font(.headline)
                Spacer()
                Button {
                    isCreatingWithPi = true
                } label: {
                    Label(loc.t("Crear con pi…", "Create with pi…"),
                          systemImage: "wand.and.stars")
                }
                Button {
                    isCreating = true
                    newDraft = PromptTemplate(name: "", body: "")
                } label: {
                    Label(loc.t("Nueva plantilla", "New template"),
                          systemImage: "plus")
                }
            }
            .padding()

            Divider()

            HSplitView {
                List(selection: $selectedID) {
                    ForEach(templates) { template in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).font(.body.weight(.medium))
                            Text(template.body.prefix(80).replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if activeVariantKey(of: template)
                                != PromptTemplate.defaultVariantKey {
                                Text(loc.t("variante activa: %@",
                                           "active variant: %@", template.activeVariant ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(template.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                templates.removeAll { $0.id == template.id }
                                PromptLibrary.save(templates)
                                if selectedID == template.id { selectedID = nil }
                            } label: {
                                Label(loc.t("Eliminar", "Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
                .frame(minWidth: 220, idealWidth: 260)

                VStack(alignment: .leading, spacing: 12) {
                    if isCreating {
                        TextField(loc.t("Nombre", "Name"), text: $newDraft.name)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $newDraft.body)
                            .font(.body)
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary))
                        HStack {
                            Button(loc.t("Guardar plantilla", "Save template")) {
                                guard !newDraft.name.trimmingCharacters(in: .whitespaces)
                                    .isEmpty else { return }
                                templates.append(newDraft)
                                PromptLibrary.save(templates)
                                selectedID = newDraft.id
                                isCreating = false
                            }
                            .disabled(newDraft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {
                                isCreating = false
                            }
                        }
                    } else if let template = selected {
                        Text(template.name).font(.title3.weight(.semibold))
                        variantSwitcher(template)
                        TextEditor(text: $editingBody)
                            .font(.body)
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary))
                            .onChange(of: editingBody) { _, newBody in
                                guard let i = templates.firstIndex(where: { $0.id == template.id })
                                else { return }
                                // With a variant active, edits go to the
                                // variant body; otherwise to the main body.
                                let key = activeVariantKey(of: templates[i])
                                if key != PromptTemplate.defaultVariantKey {
                                    var variants = templates[i].variants ?? [:]
                                    variants[key] = newBody
                                    templates[i].variants = variants
                                } else {
                                    templates[i].body = newBody
                                }
                                templates[i].updated = Date()
                            }
                        variableEditor(template)
                        HStack {
                            Button {
                                PromptLibrary.save(templates)
                            } label: {
                                Label(loc.t("Guardar cambios", "Save changes"),
                                      systemImage: "square.and.arrow.down")
                            }
                            Spacer()
                            Button {
                                let rendered = PromptLibrary.apply(
                                    template.effectiveBody, template: template,
                                    values: values, workingDirectory: workingDirectory)
                                onApply(rendered)
                                dismiss()
                            } label: {
                                Label(loc.t("Aplicar como prompt del sistema",
                                            "Apply as system prompt"),
                                      systemImage: "checkmark.circle.fill")
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                        }
                        Text(loc.t(
                            "Se aplica a este chat y sustituye su prompt de sistema actual.",
                            "Applies to this chat and replaces its current system prompt."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(loc.t("Selecciona una plantilla.",
                                   "Select a template."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .center)
                    }
                    Spacer()
                }
                .padding()
                .frame(minWidth: 380, idealWidth: 460)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .sheet(isPresented: $isCreatingWithPi) {
            CreateWithPiSheet { template in
                templates.append(template)
                PromptLibrary.save(templates)
                selectedID = template.id
                editingBody = template.body
                values = [:]
            }
            .environmentObject(loc)
        }
        .onAppear {
            templates = PromptLibrary.load()
            selectedID = templates.first?.id
            editingBody = templates.first?.effectiveBody ?? ""
        }
        .onChange(of: selectedID) { _, newValue in
            editingBody = templates.first { $0.id == newValue }?.effectiveBody ?? ""
            values = [:]
            newVariantName = ""
        }
        .onChange(of: activeVariantKey) { _, _ in
            // Following the switcher, the editor shows the newly active body.
            editingBody = selected?.effectiveBody ?? ""
        }
    }

    // MARK: Variant switcher (llm-space variable variants)

    @ViewBuilder
    private func variantSwitcher(_ template: PromptTemplate) -> some View {
        HStack(spacing: 8) {
            Text(loc.t("Variante", "Variant"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: variantBinding(template)) {
                Text(loc.t("Principal (default)", "Main (default)"))
                    .tag(PromptTemplate.defaultVariantKey)
                ForEach(variantKeys, id: \.self) { key in
                    Text(key).tag(key)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            TextField(loc.t("Nueva variante", "New variant"), text: $newVariantName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            Button {
                addVariant(template)
            } label: {
                Image(systemName: "plus")
            }
            .disabled(newVariantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(loc.t("Duplica el cuerpo actual como variante A/B.",
                        "Duplicates the current body as an A/B variant."))
            if activeVariantKey != PromptTemplate.defaultVariantKey {
                Button(role: .destructive) {
                    deleteActiveVariant(template)
                } label: {
                    Image(systemName: "trash")
                }
                .help(loc.t("Elimina la variante activa.", "Deletes the active variant."))
            }
        }
    }

    private func addVariant(_ template: PromptTemplate) {
        let key = newVariantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != PromptTemplate.defaultVariantKey,
              let i = templates.firstIndex(where: { $0.id == template.id }),
              templates[i].variants?[key] == nil else { return }
        // Start the variant as a copy of the body being shown, so A/B is a
        // one-click divergence. (Build the map first: subscripting through a
        // nil `variants` would silently drop the assignment.)
        var variants = templates[i].variants ?? [:]
        variants[key] = templates[i].effectiveBody
        templates[i].variants = variants
        templates[i].activeVariant = key
        templates[i].updated = Date()
        editingBody = templates[i].effectiveBody
        newVariantName = ""
    }

    private func deleteActiveVariant(_ template: PromptTemplate) {
        let key = activeVariantKey
        guard key != PromptTemplate.defaultVariantKey,
              let i = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[i].variants?[key] = nil
        if templates[i].variants?.isEmpty == true { templates[i].variants = nil }
        templates[i].activeVariant = nil
        templates[i].updated = Date()
        editingBody = templates[i].effectiveBody
    }

    private func variantBinding(_ template: PromptTemplate) -> Binding<String> {
        Binding(
            get: { activeVariantKey },
            set: { newKey in
                guard let i = templates.firstIndex(where: { $0.id == template.id })
                else { return }
                templates[i].activeVariant =
                    newKey == PromptTemplate.defaultVariantKey ? nil : newKey
            })
    }

    private func activeVariantKey(of template: PromptTemplate) -> String {
        guard let key = template.activeVariant?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key != PromptTemplate.defaultVariantKey,
              template.variants?[key] != nil else { return PromptTemplate.defaultVariantKey }
        return key
    }

    // MARK: Variable editor (llm-space typed variables)

    @ViewBuilder
    private func variableEditor(_ template: PromptTemplate) -> some View {
        if !selectedVariables.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("Variables", "Variables"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(selectedVariables, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("{{\(name)}}")
                                .font(.caption.monospaced())
                                .frame(width: 110, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Picker("", selection: typeBinding(name, template: template)) {
                                Text(loc.t("Texto", "Text"))
                                    .tag(PromptVariableType.text)
                                Text(loc.t("Fecha actual", "Current date"))
                                    .tag(PromptVariableType.currentDate)
                                Text(loc.t("Directorio de trabajo", "Working directory"))
                                    .tag(PromptVariableType.workingDirectory)
                                Text(loc.t("Skills", "Skills"))
                                    .tag(PromptVariableType.skills)
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                        if specType(name, template: template) == .text {
                            TextField(name, text: binding(value: name))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Text(resolvedHint(name, template: template))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(4)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(.quaternary.opacity(0.4)))
                        }
                    }
                }
            }
        }
    }

    private func specType(_ name: String, template: PromptTemplate) -> PromptVariableType {
        template.variables?
            .first { $0.name.lowercased() == name.lowercased() }?.type ?? .text
    }

    private func typeBinding(_ name: String, template: PromptTemplate)
        -> Binding<PromptVariableType> {
        Binding(
            get: { specType(name, template: template) },
            set: { newType in
                guard let i = templates.firstIndex(where: { $0.id == template.id })
                else { return }
                var specs = templates[i].variables ?? []
                if let j = specs.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    specs[j].type = newType
                } else {
                    specs.append(PromptVariableSpec(name: name, type: newType, format: nil))
                }
                templates[i].variables = specs
                templates[i].updated = Date()
            })
    }

    /// One-line preview of what a typed variable resolves to right now, so
    /// the picker's effect is visible before applying.
    private func resolvedHint(_ name: String, template: PromptTemplate) -> String {
        let spec = template.variables?
            .first { $0.name.lowercased() == name.lowercased() }
        switch spec?.type ?? .text {
        case .text:
            return ""
        case .currentDate:
            return PromptLibrary.formattedDate(Date(), format: spec?.format)
        case .workingDirectory:
            return PromptLibrary.resolveWorkingDirectory(workingDirectory)
        case .skills:
            let list = SkillsDiscovery.markdownList(
                maxSkills: PromptLibrary.skillsVariableMaxSkills)
            return list.isEmpty
                ? loc.t("Sin skills detectadas: el marcador se mantiene visible.",
                        "No skills found: the placeholder stays visible.")
                : list
        }
    }

    private func binding(value name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 })
    }
}

// MARK: - Create with pi sheet

/// llm-space's meta-prompt harness UI: a task description (+ an optional
/// existing prompt to improve) run through `MetaPromptService.run`, which
/// authors a system prompt with pi and returns it — or a bilingual failure
/// message, never a silent fallback. The authored text is saved as a new
/// template named from the task's first words.
private struct CreateWithPiSheet: View {
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    /// Receives the saved template (the parent appends, persists, selects).
    let onSaved: (PromptTemplate) -> Void

    @State private var task = ""
    @State private var existing = ""
    @State private var isRunning = false
    @State private var failure: String?
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(loc.t("Crear con pi", "Create with pi"), systemImage: "wand.and.stars")
                .font(.headline)
            Text(loc.t("Describe la tarea y pi escribirá el prompt.",
                       "Describe the task and pi will write the prompt."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(loc.t("Tarea", "Task"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $task)
                .font(.body)
                .frame(minHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .disabled(isRunning)
            Text(loc.t("Prompt existente (opcional)", "Existing prompt (optional)"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $existing)
                .font(.body)
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .disabled(isRunning)
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc.t("pi está escribiendo el prompt…",
                               "pi is writing the prompt…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let failure {
                // Already bilingual from the service ("es / en"); half()
                // shows the active language's half, per repo convention.
                Text(loc.half(failure))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let result {
                Text(loc.t("Resultado (guardado como plantilla):",
                           "Result (saved as a template):"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(result)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            Spacer(minLength: 0)
            HStack {
                Button {
                    run()
                } label: {
                    Label(loc.t("Crear prompt", "Create prompt"),
                          systemImage: "wand.and.stars")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isRunning)
                Spacer()
                Button(loc.t("Cerrar", "Close")) {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(minWidth: 460, idealWidth: 520, minHeight: 460, idealHeight: 520)
    }

    private func run() {
        let taskText = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskText.isEmpty, !isRunning else { return }
        let existingText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        isRunning = true
        failure = nil
        result = nil
        Task {
            // llm-space feeds the skills list into the authoring run the same
            // way typed `skills` variables resolve at apply time.
            let skills = SkillsDiscovery.markdownList(
                maxSkills: PromptLibrary.skillsVariableMaxSkills)
            let output = await MetaPromptService.run(
                taskDescription: taskText,
                existingPrompt: existingText.isEmpty ? nil : existingText,
                skillsList: skills)
            isRunning = false
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Pure-failure results (empty task guard, empty reply): surface
            // the bilingual text and save nothing — there is no authored
            // prompt to keep. Everything else is the authored text (a run
            // that ended abnormally still carries its partial text plus the
            // bilingual failure note, so the failure is visible either way).
            if trimmed == MetaPromptService.emptyTaskMessage
                || trimmed.hasPrefix(MetaPromptService.emptyReplyMessage) {
                failure = trimmed
                return
            }
            guard !trimmed.isEmpty else {
                failure = loc.t("pi no devolvió ningún texto. Vuelve a intentarlo.",
                                "pi returned no text. Try again.")
                return
            }
            let name = PromptLibrary.name(fromTask: taskText)
            let template = PromptTemplate(
                name: name.isEmpty ? loc.t("Prompt de pi", "pi prompt") : name,
                body: output)
            result = output
            onSaved(template)
        }
    }
}
