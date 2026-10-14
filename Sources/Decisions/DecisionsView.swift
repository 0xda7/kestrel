// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Decisions section: run documents through the Laya decision engine
/// with a stored question set, keep every run in history, batch N
/// documents, export everything. The run button follows the live
/// "Laya Decisions" server card — nothing starts in the background.
struct DecisionsView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var manager: ServerManager
    @StateObject private var controller = LayaDecisionsController()
    @State private var showingSets = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(loc.t("Modo", "Mode"), selection: $controller.mode) {
                    Text(loc.t("Documento", "Document")).tag(LayaDecisionsController.Mode.single)
                    Text(loc.t("Lote", "Batch")).tag(LayaDecisionsController.Mode.batch)
                    Text(loc.t("Historial", "History")).tag(LayaDecisionsController.Mode.history)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                LayaServerCardStatus(running: controller.running)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()

            switch controller.mode {
            case .single: singleMode
            case .batch: LayaBatchView(controller: controller)
            case .history: LayaHistoryView(controller: controller)
            }
        }
        .background(WorkspaceStyle.canvas)
        .onAppear {
            controller.reloadSets()
            controller.reloadHistory()
        }
        .sheet(isPresented: $showingSets) {
            LayaQuestionSetsSheet(selectedSetName: $controller.selectedSetName) {
                controller.reloadSets()
            }
        }
    }

    private var singleMode: some View {
        HSplitView {
            // Input column
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Document input: file picker + paste
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loc.t("Documento", "Document"), systemImage: "doc.text")
                            .font(.headline)
                        HStack(spacing: 8) {
                            Button {
                                controller.pickDocument()
                            } label: {
                                Label(controller.documentURL == nil
                                      ? loc.t("Elegir archivo…", "Choose file…")
                                      : controller.documentURL?.lastPathComponent ?? "",
                                      systemImage: "folder")
                                    .lineLimit(1)
                            }
                            .glassButton()
                            .help(loc.t("Un archivo de texto para decidir (.txt, .md, .json…).",
                                        "A text file to decide on (.txt, .md, .json…)."))
                            if controller.documentURL != nil {
                                Button {
                                    controller.clearDocument()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help(loc.t("Volver a texto pegado", "Back to pasted text"))
                            }
                        }
                        if controller.documentURL == nil {
                            TextEditor(text: $controller.documentText)
                                .font(.system(.callout, design: .monospaced))
                                .frame(height: 170)
                                .padding(4)
                                .background(WorkspaceStyle.inset,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(WorkspaceStyle.border))
                            Text(loc.t("…o pega el texto del documento aquí.",
                                       "…or paste the document text here."))
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text(controller.documentText)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(6)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Question set
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(loc.t("Conjunto de preguntas", "Question set"),
                                  systemImage: "checklist")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingSets = true
                            } label: {
                                Label(loc.t("Gestionar", "Manage"), systemImage: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .help(loc.t("Crear, editar, duplicar o borrar conjuntos en ~/Library/Application Support/Kestrel/laya-questions.",
                                        "Create, edit, duplicate or delete sets in ~/Library/Application Support/Kestrel/laya-questions."))
                        }
                        Picker(loc.t("Conjunto", "Set"), selection: $controller.selectedSetName) {
                            ForEach(controller.sets, id: \.name) { set in
                                Text("\(set.name) (\(set.questions.count))").tag(set.name)
                            }
                        }
                        if let set = controller.selectedSet {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(set.questions.sorted { $0.key < $1.key }, id: \.key) { key, q in
                                    Text("· \(key) — \(q.instructions)")
                                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                    }

                    runControls
                }
                .padding(16)
            }
            .frame(minWidth: 330, maxWidth: 460)

            // Results column
            ScrollView {
                if let run = controller.currentRun {
                    LayaRunDetailView(run: run)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checklist")
                            .font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text(loc.t("La tarjeta de decisiones aparecerá aquí.",
                                   "The decision card will appear here."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .frame(minWidth: 380)
        }
    }

    @ViewBuilder
    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                controller.runSingle()
            } label: {
                HStack {
                    if controller.running { ProgressView().controlSize(.small) }
                    Label(loc.t("Decidir", "Decide"), systemImage: "bolt.horizontal")
                }
                .frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .controlSize(.large)
            .disabled(!controller.canRunSingle)

            if let error = controller.runError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.currentRun != nil, controller.running == false {
                HStack {
                    Button {
                        controller.exportRunCSV()
                    } label: {
                        Label("CSV", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                    Button {
                        controller.exportRunJSON()
                    } label: {
                        Label("JSON", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                }
            }
        }
    }
}

// MARK: - Server card awareness

/// Live status of the "Laya Decisions" server card: what the run button
/// will talk to. Offers Start when the card is stopped — the operator
/// starts the engine, never the app in the background.
struct LayaServerCardStatus: View {
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var loc: Localizer
    let running: Bool

    private var card: ServerController? {
        manager.servers.first { $0.name == "Laya Decisions" }
    }

    var body: some View {
        if let card {
            LayaServerCardLive(server: card, busy: running)
        } else {
            Label(loc.t("Falta la tarjeta «Laya Decisions» — se crea al iniciar Kestrel cuando ~/models/Laya-Q8_0.gguf existe.",
                        "The “Laya Decisions” card is missing — it is created at app launch when ~/models/Laya-Q8_0.gguf exists."),
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
                .help(loc.t("Sin tarjeta no hay motor al que llamar.",
                            "Without the card there is no engine to call."))
        }
    }
}

private struct LayaServerCardLive: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var loc: Localizer
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            switch server.state {
            case .running:
                Label(loc.t("Laya en el puerto %@", "Laya on port %@", "\(server.effectiveSettings().port)"),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .starting:
                Label(loc.t("Cargando Laya…", "Loading Laya…"), systemImage: "hourglass")
                    .foregroundStyle(.orange)
            case .failed:
                Label(loc.t("Laya: error", "Laya: failed"), systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            case .stopped:
                Label(loc.t("Laya parado", "Laya stopped"), systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                Button(loc.t("Iniciar", "Start")) {
                    server.start(server.effectiveSettings())
                }
                .glassButton()
                .disabled(busy)
                .help(loc.t("Arranca la tarjeta «Laya Decisions» (lo mismo que pulsar Start en la pestaña Servers).",
                            "Starts the “Laya Decisions” card (same as pressing Start on the Servers tab)."))
            }
        }
        .font(.caption)
    }
}

// MARK: - Controller

@MainActor
final class LayaDecisionsController: ObservableObject {
    enum Mode: Hashable { case single, batch, history }

    // Section state
    @Published var mode: Mode = .single

    // Document input
    @Published var documentURL: URL?
    @Published var documentText = ""

    // Question sets
    @Published var sets: [LayaDecideService.QuestionSet] = []
    @Published var selectedSetName = ""

    // Run state
    @Published var running = false
    @Published var runError: String?
    @Published var currentRun: LayaRunStore.Run?

    // History
    @Published var history: [LayaRunStore.Run] = []
    @Published var openedRunID: UUID?

    // Batch
    @Published var batch: LayaRunStore.Batch?
    @Published var batchRunning = false
    @Published var batchProgress = ""
    @Published var batchError: String?

    var selectedSet: LayaDecideService.QuestionSet? {
        sets.first { $0.name == selectedSetName }
    }

    var canRunSingle: Bool {
        !running && documentText.nilIfBlank != nil && selectedSet != nil
    }

    var openedRun: LayaRunStore.Run? {
        history.first { $0.id == openedRunID }
    }

    func reloadSets() {
        sets = LayaDecideService.loadSets()
        if selectedSet == nil { selectedSetName = sets.first?.name ?? "" }
    }

    func reloadHistory() {
        history = LayaRunStore.loadRuns()
        if let openedRunID, !history.contains(where: { $0.id == openedRunID }) {
            self.openedRunID = nil
        }
    }

    // MARK: Document input

    /// The SDK ships no `UTType.markdown` member; this is the system-declared
    /// UTI for Markdown (falling back to plain text if a system lacks it).
    static let markdownDocument = UTType("net.daringfireball.markdown") ?? .plainText

    func pickDocument() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .json, Self.markdownDocument, .sourceCode, .yaml]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        documentURL = url
        documentText = text
        runError = nil
    }

    func clearDocument() {
        documentURL = nil
        documentText = ""
    }

    // MARK: Single run

    func runSingle() {
        guard let set = selectedSet else {
            runError = "Select a question set first."
            return
        }
        guard let document = documentText.nilIfBlank else {
            runError = "The document is empty — pick a file or paste text."
            return
        }
        running = true
        runError = nil
        let name = documentURL?.lastPathComponent ?? "Pasted text"
        let source = documentURL == nil ? "paste" : "file"
        Task { @MainActor in
            defer { running = false }
            do {
                let run = try await decide(document: document, set: set,
                                           documentName: name, documentSource: source)
                LayaRunStore.save(run)
                currentRun = run
                reloadHistory()
            } catch {
                runError = readable(error)
            }
        }
    }

    /// Shared engine call for single and batch: resolve the card's port at
    /// call time (an operator edit must steer every run) and health-check
    /// first so the guidance is start-it-yourself, not a timeout.
    private func decide(document: String, set: LayaDecideService.QuestionSet,
                        documentName: String, documentSource: String) async throws -> LayaRunStore.Run {
        let port = LayaDecideService.resolvedPort()
        guard await LayaDecideService.engineHealth(port: port) else {
            throw LayaDecideService.LayaError.engineDown
        }
        let answers = try await LayaDecideService.decide(document: document,
                                                         questions: set.questions,
                                                         port: port)
        return LayaRunStore.Run(id: UUID(), date: Date(), documentName: documentName,
                                documentSource: documentSource, setName: set.name,
                                questionSet: set, answers: answers)
    }

    private func readable(_ error: Error) -> String {
        (error as? LayaDecideService.LayaError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Batch

    func pickBatchDocuments() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .json, Self.markdownDocument, .sourceCode, .yaml]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        runBatch(urls: panel.urls)
    }

    func runBatch(urls: [URL]) {
        guard let set = selectedSet else {
            batchError = "Select a question set first."
            return
        }
        batchRunning = true
        batchError = nil
        var batch = LayaRunStore.Batch(id: UUID(), date: Date(), setName: set.name,
                                       questionSet: set, rows: [])
        Task { @MainActor in
            defer {
                batchRunning = false
                batchProgress = ""
                self.batch = batch
            }
            for (index, url) in urls.enumerated() {
                batchProgress = "\(index + 1)/\(urls.count) — \(url.lastPathComponent)"
                do {
                    let document = try String(contentsOf: url, encoding: .utf8)
                    let run = try await decide(document: document, set: set,
                                               documentName: url.lastPathComponent,
                                               documentSource: "file")
                    batch.rows.append(.init(id: UUID(), documentName: url.lastPathComponent,
                                            error: nil, answers: run.answers))
                } catch {
                    batch.rows.append(.init(id: UUID(), documentName: url.lastPathComponent,
                                            error: readable(error), answers: [:]))
                }
            }
        }
    }

    // MARK: Exports (same save-panel pattern as the chat archive exports)

    func exportRunCSV() {
        guard let run = currentRun else { return }
        exportData(Data(LayaRunStore.csv(for: run).utf8),
                   name: "laya-run-\(safeFileStem(run.documentName)).csv", type: .commaSeparatedText)
    }

    func exportRunJSON() {
        guard let run = currentRun else { return }
        exportData(try? LayaRunStore.jsonData(for: run),
                   name: "laya-run-\(safeFileStem(run.documentName)).json", type: .json)
    }

    func exportHistoryCSV() {
        exportData(Data(LayaRunStore.historyCSV(history).utf8),
                   name: "laya-history.csv", type: .commaSeparatedText)
    }

    func exportHistoryRowCSV(_ run: LayaRunStore.Run) {
        exportData(Data(LayaRunStore.csv(for: run).utf8),
                   name: "laya-run-\(safeFileStem(run.documentName)).csv", type: .commaSeparatedText)
    }

    func exportHistoryRowJSON(_ run: LayaRunStore.Run) {
        exportData(try? LayaRunStore.jsonData(for: run),
                   name: "laya-run-\(safeFileStem(run.documentName)).json", type: .json)
    }

    func deleteRun(_ run: LayaRunStore.Run) {
        LayaRunStore.deleteRun(id: run.id)
        reloadHistory()
    }

    func exportHistoryJSON() {
        exportData(try? LayaRunStore.historyJSONData(history),
                   name: "laya-history.json", type: .json)
    }

    func exportBatchCSV() {
        guard let batch else { return }
        exportData(Data(LayaRunStore.csv(for: batch).utf8),
                   name: "laya-batch.csv", type: .commaSeparatedText)
    }

    func exportBatchJSON() {
        guard let batch else { return }
        exportData(try? LayaRunStore.jsonData(for: batch),
                   name: "laya-batch.json", type: .json)
    }

    private func exportData(_ data: Data?, name: String, type: UTType) {
        guard let data else {
            runError = "Could not build the export."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            runError = error.localizedDescription
        }
    }

    private func safeFileStem(_ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? "run" : stem
    }
}

// MARK: - Results

/// One run's answers as native decision cards.
struct LayaRunDetailView: View {
    @EnvironmentObject private var loc: Localizer
    let run: LayaRunStore.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(run.documentName, systemImage: "doc.text.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(run.setName).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.appAccent.opacity(0.14), in: Capsule())
                Spacer()
                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(run.questionSet.questions.sorted { $0.key < $1.key }, id: \.key) { key, question in
                LayaAnswerCard(key: key, question: question, answer: run.answers[key])
            }
        }
        .padding(16)
    }
}

// MARK: - History

struct LayaHistoryView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var controller: LayaDecisionsController

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(loc.t("Historial de decisiones", "Decision history"),
                          systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Button {
                        controller.exportHistoryCSV()
                    } label: { Label("CSV", systemImage: "square.and.arrow.up") }
                        .glassButton()
                        .disabled(controller.history.isEmpty)
                    Button {
                        controller.exportHistoryJSON()
                    } label: { Label("JSON", systemImage: "square.and.arrow.up") }
                        .glassButton()
                        .disabled(controller.history.isEmpty)
                    Button {
                        controller.reloadHistory()
                    } label: { Label(loc.t("Recargar", "Reload"), systemImage: "arrow.clockwise") }
                        .glassButton()
                }
                .padding(12)
                Divider()
                if controller.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(loc.t("Cada decisión completada se guarda en …/Kestrel/laya-runs.",
                                   "Every completed decision is stored in …/Kestrel/laya-runs."))
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $controller.openedRunID) {
                        ForEach(controller.history) { run in
                            LayaHistoryRow(run: run)
                                .tag(run.id)
                                .contextMenu {
                                    Button(loc.t("Abrir", "Open")) { controller.openedRunID = run.id }
                                    Button(loc.t("Exportar CSV", "Export CSV")) {
                                        controller.exportHistoryRowCSV(run)
                                    }
                                    Button(loc.t("Exportar JSON", "Export JSON")) {
                                        controller.exportHistoryRowJSON(run)
                                    }
                                    Button(loc.t("Eliminar", "Delete"), role: .destructive) {
                                        controller.deleteRun(run)
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 330, maxWidth: 470)

            ScrollView {
                if let run = controller.openedRun {
                    LayaRunDetailView(run: run)
                } else {
                    Text(loc.t("Abre una decisión del historial para verla de nuevo.",
                               "Open a decision from the history to view it again."))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .frame(minWidth: 380)
        }
    }
}

private struct LayaHistoryRow: View {
    let run: LayaRunStore.Run

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.documentSource == "file" ? "doc.text" : "doc.on.clipboard")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.documentName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(run.setName) · \(run.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - Batch

struct LayaBatchView: View {
    @EnvironmentObject private var loc: Localizer
    @ObservedObject var controller: LayaDecisionsController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    controller.pickBatchDocuments()
                } label: {
                    Label(loc.t("Elegir documentos…", "Choose documents…"), systemImage: "doc.badge.plus")
                }
                .glassButton()
                .disabled(controller.batchRunning)
                .help(loc.t("Selecciona varios archivos de texto; se deciden en orden con el conjunto activo.",
                            "Select several text files; they are decided in order with the active set."))
                if controller.batchRunning {
                    ProgressView().controlSize(.small)
                    Text(controller.batchProgress).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let batch = controller.batch {
                    Text(loc.t("%@ de %@ documentos", "%@ of %@ documents",
                               "\(batch.rows.filter { $0.error == nil }.count)", "\(batch.rows.count)"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button { controller.exportBatchCSV() } label: { Label("CSV", systemImage: "square.and.arrow.up") }
                        .glassButton()
                    Button { controller.exportBatchJSON() } label: { Label("JSON", systemImage: "square.and.arrow.up") }
                        .glassButton()
                }
            }
            .padding(12)
            Divider()

            if let batch = controller.batch {
                LayaBatchTable(batch: batch)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(loc.t("Elige N documentos; la tabla de resultados y su exportación aparecerán aquí.",
                               "Choose N documents; the results table and its export will appear here."))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = controller.batchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }
}

/// Batch results table: one row per document, one answer + confidence
/// column pair per question — the export's on-screen twin.
private struct LayaBatchTable: View {
    let batch: LayaRunStore.Batch

    private var keys: [String] {
        batch.questionSet.questions.keys.sorted()
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    headerCell("document")
                    headerCell("status")
                    ForEach(keys, id: \.self) { key in
                        headerCell(key)
                        headerCell("\(key) confidence")
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(batch.rows) { row in
                    GridRow {
                        Text(row.documentName)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Text(row.error == nil ? "ok" : "failed")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(row.error == nil ? Color.green : Color.red)
                            .help(row.error ?? "")
                        ForEach(keys, id: \.self) { key in
                            let shaped = LayaRunStore.answerFields(row.answers[key])
                            Text(row.error == nil ? shaped.text : "")
                                .font(.system(.caption, design: .monospaced))
                            Text(row.error == nil ? shaped.confidence : "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .padding(14)
        }
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
