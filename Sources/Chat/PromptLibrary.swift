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
/// ride any engine's system-prompt surface.
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
    /// Resolved through AppSupport so the harness override covers the
    /// library exactly like every other live-data store; the production
    /// path (Application Support/Kestrel) is unchanged.
    static var fileURL: URL {
        AppSupport.directory.appendingPathComponent("prompt-library.json")
    }

    /// Loads the library, seeding first-run defaults so the space is never
    /// empty. A missing file is the normal first-launch case and seeds; a
    /// file that EXISTS but fails to decode is corrupt: it is moved aside to
    /// `<name>.unreadable` (the recovery path) before reseeding, so the
    /// reseed can never destroy the user's only copy; a READ failure (EIO,
    /// disk hiccup) serves the seeds in memory and does NOT overwrite the
    /// file — one bad read must never destroy every saved template.
    static func load() -> [PromptTemplate] { load(from: fileURL) }

    /// The load logic against an explicit store path — internal so
    /// SidecarStoreSurfacingTests can pin the corrupt-file recovery.
    static func load(from url: URL) -> [PromptTemplate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            let seeded = seedTemplates
            save(seeded, to: url)
            return seeded
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Census W8 :93 — exists but unreadable: keep the file, serve the
            // seeds, and let a later launch retry the read. Surfaced, no
            // longer silent.
            AppLog.app.error("prompt library \(url.lastPathComponent) could not be read: \(error.localizedDescription) — serving the default templates in memory; the file is untouched so a later launch can retry the read")
            return seedTemplates
        }
        do {
            let templates = try JSONDecoder().decode([PromptTemplate].self, from: data)
            if !templates.isEmpty { return templates }
            // Decodes to an empty library: fall through to the reseed.
        } catch {
            // Census W8 :94 — corrupt beyond repair: preserve the user's
            // bytes aside BEFORE the reseed can overwrite them.
            let aside = url.appendingPathExtension("unreadable")
            do {
                if fm.fileExists(atPath: aside.path) { try fm.removeItem(at: aside) }
                try fm.moveItem(at: url, to: aside)
                AppLog.app.error("prompt library \(url.lastPathComponent) was corrupt: \(error.localizedDescription) — moved to \(aside.lastPathComponent) and reseeded; the original templates are recoverable there")
            } catch {
                AppLog.app.error("prompt library \(url.lastPathComponent) was corrupt and could not be moved aside: \(error.localizedDescription) — serving the default templates in memory; the file is left untouched so nothing is destroyed")
                return seedTemplates
            }
        }
        let seeded = seedTemplates
        save(seeded, to: url)
        return seeded
    }

    static func save(_ templates: [PromptTemplate]) { save(templates, to: fileURL) }

    /// The save logic against an explicit store path — internal so the check
    /// suite can drive it with temp files. Census W8 :111/:113/:114 — every
    /// persistence failure is surfaced; the user's edits may never silently
    /// fail to stick.
    static func save(_ templates: [PromptTemplate], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                atPath: url.deletingLastPathComponent().path,
                withIntermediateDirectories: true)
        } catch {
            AppLog.app.error("prompt library folder could not be created: \(error.localizedDescription) — templates will not persist")
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(templates)
        } catch {
            AppLog.app.error("prompt library could not be encoded: \(error.localizedDescription) — templates will not persist")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.app.error("prompt library \(url.lastPathComponent) could not be written: \(error.localizedDescription) — templates will not persist")
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
}

// MARK: - Prompt Space sheet

/// The Prompt Space (wave 1): browse the template library, fill its
/// variables, apply the render as this conversation's system prompt. Editing
/// and creating templates lives in the same sheet so the loop stays closed.
/// Wave 2 adds llm-space's typed variables and A/B variants.
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

