// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

struct LocalModel: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let partURLs: [URL]
    var id: String { url.path }
    var sizeGB: String { String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824) }
    var isMoE: Bool {
        if let metadata = GGUFMetadataCache.metadata(at: url.path) {
            return metadata.isMoE
        }
        return ModelName.looksMoE(name)
    }

    init(url: URL, name: String, sizeBytes: Int64, partURLs: [URL]? = nil) {
        self.url = url
        self.name = name
        self.sizeBytes = sizeBytes
        self.partURLs = partURLs ?? [url]
    }

    /// Recursive `.gguf` scan, excluding managed media folders, projectors and drafts.
    /// Shared by `ModelStore.refresh()` and the router preset generator.
    nonisolated static func scan(in directory: URL) -> [LocalModel] {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Census W8 Models:33 (T2-3 chunk E): the scan used to run even
            // when the models folder could not be created, with the failure
            // silent. Scanning proceeds as before (the enumerator then finds
            // nothing); the miss is named. T2-2 chunk B pattern.
            let notice = ModelStore.directoryCreationFailureNotice(
                directory: directory.path, purpose: "the models folder",
                reason: error.localizedDescription)
            AppLog.app.error("\(notice, privacy: .public)")
        }
        return models(from: ModelFileIndex.scan(in: directory).llmFiles)
    }

    nonisolated static func models(from files: [URL]) -> [LocalModel] {
        let entries = files.map { url -> GGUFFileEntry in
            let resourceSize: Int?
            do {
                resourceSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            } catch {
                // Census W8 Models:39 (T2-3 chunk E): an unreadable size used
                // to count the entry as 0 bytes with no trace — for a shard
                // set that quietly under-reports the total the VRAM math then
                // trusts. The 0 stays (entries byte-identical), but the gap
                // is named; a size that is genuinely absent without any error
                // keeps the silent 0.
                let notice = Self.modelSizeFailureNotice(
                    file: url.lastPathComponent, reason: error.localizedDescription)
                AppLog.app.error("\(notice, privacy: .public)")
                resourceSize = nil
            }
            return GGUFFileEntry(path: url.path, sizeBytes: resourceSize.map(Int64.init) ?? 0)
        }
        return GGUFFile.models(from: entries)
            .map { group in
                let url = URL(fileURLWithPath: group.primaryPath)
                return LocalModel(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: group.sizeBytes,
                    partURLs: group.paths.map { URL(fileURLWithPath: $0) }
                )
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Census W8 Models:39 (T2-3 chunk E): the English line for a model file
    /// whose size could not be read; it still counts as 0 bytes (the
    /// long-standing entry shape), so a suspicious 0 now has a trace. Pure so
    /// checks can pin the line (D3).
    nonisolated static func modelSizeFailureNotice(file: String, reason: String) -> String {
        "Could not read the size of \(file); it counts as 0 bytes until a scan reads it: \(reason)"
    }
}


enum ResumableDownload {
    enum ResponsePlan: Equatable {
        case append(totalBytes: Int64?)
        case restart(totalBytes: Int64?)
        case alreadyComplete
        case reject
    }

    static func request(remote: URL, partialBytes: Int64) -> URLRequest {
        var request = URLRequest(url: remote)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if partialBytes > 0 {
            request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func responsePlan(statusCode: Int, contentRange: String?, contentLength: Int64,
                             partialBytes: Int64, expectedBytes: Int64?) -> ResponsePlan {
        if statusCode == 416, let expectedBytes, partialBytes == expectedBytes {
            return .alreadyComplete
        }
        if statusCode == 206 {
            guard let range = contentRange,
                  range.lowercased().hasPrefix("bytes \(partialBytes)-") else { return .reject }
            let total = range.split(separator: "/").last.flatMap { Int64($0) }
            return .append(totalBytes: total ?? expectedBytes)
        }
        if (200...299).contains(statusCode) {
            let total = contentLength > 0 ? contentLength : expectedBytes
            return .restart(totalBytes: total)
        }
        return .reject
    }
}

private final class DownloadSink: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) { self.url = url }

    func size() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            // Census W8 Models:102 (T2-3 chunk E): an unreadable partial used
            // to resume from 0 (a full re-download) with no trace. The 0 stays
            // — restarting from scratch is the safe direction — but the gap
            // is named.
            AppLog.downloads.error("Could not read the size of the partial download \(self.url.lastPathComponent, privacy: .public); resuming from the start: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    func open(append: Bool) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        do {
            try handle?.close()
        } catch {
            // Census W8 Models:107 (T2-3 chunk E): the stale handle's close
            // failing must not abort the fresh open — the new handle governs
            // the transfer from here — so the failure is named, not surfaced.
            AppLog.downloads.error("Could not close the previous handle of \(self.url.lastPathComponent, privacy: .public) before reopening: \(error.localizedDescription, privacy: .public)")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let next = try FileHandle(forWritingTo: url)
        if append {
            try next.seekToEnd()
        } else {
            try next.truncate(atOffset: 0)
        }
        handle = next
        return Int64(try next.offset())
    }

    func append(_ data: Data) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        try handle.write(contentsOf: data)
        return Int64(try handle.offset())
    }

    /// Closes the handle and returns the close failure, if any. The caller
    /// decides whether it can surface (a finished transfer, where the close is
    /// the results channel) or must stay secondary (pause/cancel already carry
    /// their own outcome). Nil when nothing was open or the close succeeded.
    /// Census W8 Models:131 (T2-3 chunk E).
    func close() -> Error? {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        self.handle = nil
        do {
            try handle.close()
            return nil
        } catch {
            return error
        }
    }
}

@MainActor
final class DownloadItem: NSObject, ObservableObject, Identifiable, URLSessionDataDelegate {
    enum Phase: Equatable {
        case preparing, downloading, paused, verifying, finished
        case failed(String)
    }

    let id = UUID()
    let remote: URL
    let destination: URL
    let fileName: String

    @Published var phase: Phase = .preparing
    @Published var progress: Double = 0
    @Published var receivedMB: Double = 0
    @Published var totalMB: Double = 0

    var onFinish: (() -> Void)?

    private var expectedSHA256: String?
    private var expectedBytes: Int64?
    private var task: URLSessionDataTask?
    private var requestedOffset: Int64 = 0
    private let sink: DownloadSink
    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)

    // Compatibility accessors used across the UI
    var finished: Bool { phase == .finished }
    var error: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    init(remote: URL, destination: URL, sessionConfiguration: URLSessionConfiguration = .default) {
        self.remote = remote
        self.destination = destination
        // The saved name, which may differ from the remote (e.g. projectors are
        // renamed to <model>.mmproj.gguf). The UI keys progress off this.
        self.fileName = destination.lastPathComponent
        self.sink = DownloadSink(url: destination.appendingPathExtension("download"))
        self.sessionConfiguration = sessionConfiguration
        super.init()
        Task { await prepare() }
    }

    /// Fetches integrity metadata, checks disk space, then starts the transfer.
    private func prepare() async {
        if let meta = await HuggingFaceAPI.fileMetadata(for: remote) {
            expectedSHA256 = meta.sha256
            expectedBytes = meta.sizeBytes
        }

        if let needed = expectedBytes {
            // volumeAvailableCapacityForImportantUsage is APFS only and reads zero on exFAT or
            // any other foreign volume, which stalls the download claiming no space is left.
            let dir = destination.deletingLastPathComponent()
            let capacity: Int64
            do {
                let values = try dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                               .volumeAvailableCapacityKey])
                let important = values.volumeAvailableCapacityForImportantUsage ?? 0
                capacity = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
            } catch {
                // Census W8 Models:193 (T2-3 chunk E): a failed free-space read
                // is "capacity unknown". The gate already proceeds on 0/unknown
                // (foreign volumes report zero), so the download starts — but
                // the skipped pre-check is named instead of reading as "plenty
                // of space".
                AppLog.downloads.warning("Could not read the free space on \(dir.path, privacy: .public); starting \(self.fileName, privacy: .public) without the disk-space pre-check: \(error.localizedDescription, privacy: .public)")
                capacity = 0
            }
            let remaining = max(0, needed - sink.size())
            if let free = Self.capacityShortfall(available: capacity, remaining: remaining) {
                let neededGB = Double(remaining) / 1_073_741_824
                let freeGB = Double(free) / 1_073_741_824
                phase = .failed(String(format: "Espacio insuficiente: %.1f GB libres, %.1f GB necesarios / not enough disk space", freeGB, neededGB))
                return
            }
            totalMB = Double(needed) / 1_048_576
        }

        startTask()
    }

    private func startTask() {
        requestedOffset = sink.size()
        let t = session.dataTask(with: ResumableDownload.request(remote: remote, partialBytes: requestedOffset))
        task = t
        phase = .downloading
        receivedMB = Double(requestedOffset) / 1_048_576
        if let expectedBytes, expectedBytes > 0 {
            progress = Double(requestedOffset) / Double(expectedBytes)
        }
        t.resume()
    }

    func pause() {
        guard phase == .downloading else { return }
        phase = .paused
        task?.cancel()
        if let closeError = sink.close() {
            // Census W8 Models:131 (T2-3 chunk E): pausing keeps the partial
            // for resume, so a failed close stays secondary (logged, never a
            // second failure over the pause); the resumed transfer's final
            // checksum still guards the result.
            AppLog.downloads.error("Could not close \(self.fileName, privacy: .public) cleanly while pausing; the partial file stays as is: \(closeError.localizedDescription, privacy: .public)")
        }
    }

    func resume() {
        guard phase == .paused else { return }
        startTask()
    }

    func cancel() {
        phase = .failed("Cancelada / cancelled")
        task?.cancel()
        if let closeError = sink.close() {
            // Census W8 Models:131 (T2-3 chunk E): the cancellation above is
            // the user-visible outcome; a failing close is logged, not raised
            // as a second error over it.
            AppLog.downloads.error("Could not close \(self.fileName, privacy: .public) cleanly while cancelling: \(closeError.localizedDescription, privacy: .public)")
        }
        session.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // URLSession parks later delegate callbacks until the disposition is
        // answered, so waiting here for the MainActor decision preserves the
        // ordering the previous async hop had — and the non-Sendable
        // completion handler never leaves its own queue.
        let verdict = OSAllocatedUnfairLock<URLSession.ResponseDisposition>(initialState: .cancel)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let d = self.respond(to: response)
            verdict.withLock { $0 = d }
            done.signal()
        }
        done.wait()
        completionHandler(verdict.withLock { $0 })
    }

    /// Decides the disposition and applies the MainActor side effects (sink
    /// open, phase, totals). Returns the disposition to answer URLSession with.
    @MainActor private func respond(to response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            phase = .failed("Respuesta de descarga inválida / invalid download response")
            return .cancel
        }
        let offset = requestedOffset
        let plan = ResumableDownload.responsePlan(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: response.expectedContentLength,
            partialBytes: offset,
            expectedBytes: expectedBytes)
        do {
            let total: Int64?
            switch plan {
            case .append(let bytes):
                _ = try sink.open(append: true)
                total = bytes
            case .restart(let bytes):
                _ = try sink.open(append: false)
                total = bytes
            case .alreadyComplete:
                total = expectedBytes
            case .reject:
                phase = .failed("El servidor rechazó la reanudación / server rejected resume request")
                return .cancel
            }
            if let total, total > 0 { totalMB = Double(total) / 1_048_576 }
            if plan == .alreadyComplete { finishTransfer() }
            return plan == .alreadyComplete ? .cancel : .allow
        } catch {
            phase = .failed(error.localizedDescription)
            return .cancel
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        let bytes: Int64
        do { bytes = try sink.append(data) } catch {
            dataTask.cancel()
            let message = error.localizedDescription
            Task { @MainActor in self.phase = .failed(message) }
            return
        }
        Task { @MainActor in
            self.receivedMB = Double(bytes) / 1_048_576
            let expected = self.expectedBytes ?? Int64(self.totalMB * 1_048_576)
            if expected > 0 { self.progress = min(1, Double(bytes) / Double(expected)) }
        }
    }

    private func finishTransfer() {
        if let closeError = sink.close() {
            // Census W8 Models:131 (T2-3 chunk E): the close is the download's
            // results channel — a failing close can leave the staged file
            // truncated, so it surfaces here instead of a later checksum
            // mismatch masking it (the chunk D close-before-read doctrine).
            phase = .failed(Self.closeFailureMessage(closeError, fileName: fileName))
            return
        }
        phase = .verifying
        let expected = expectedSHA256
        let staging = sink.url
        Task {
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                guard let expected else { return true }
                return FileHash.sha256(of: staging)?.lowercased() == expected.lowercased()
            }.value

            if ok {
                var removalError: Error?
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    removalError = error
                }
                if let removalError,
                   Self.finalizeBlocked(by: removalError,
                                        destinationExists: FileManager.default.fileExists(atPath: destination.path)) {
                    // Census W8 Models:329 (T2-3 chunk E): a destination that
                    // cannot be removed used to fall through to a move failure
                    // that named nothing. A genuinely blocked destination
                    // surfaces here and the finalize stops; an absent one (the
                    // normal first download) stays benign.
                    self.phase = .failed(Self.finalizeBlockerMessage(
                        destination: destination.lastPathComponent,
                        reason: removalError.localizedDescription))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: staging, to: destination)
                    if let expected { ModelStore.recordDigest(expected, forFile: destination.lastPathComponent) }
                    self.progress = 1
                    self.phase = .finished
                    self.onFinish?()
                } catch {
                    self.phase = .failed(error.localizedDescription)
                }
            } else {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch {
                    // Census W8 Models:340 (T2-3 chunk E): failing to discard
                    // the corrupt staging file leaves it on disk. The checksum
                    // failure below is the primary surface, so the leftover is
                    // named here rather than replacing that message.
                    AppLog.downloads.error("Could not discard the corrupt download \(staging.lastPathComponent, privacy: .public); remove it manually: \(error.localizedDescription, privacy: .public)")
                }
                AppLog.downloads.error("checksum mismatch for \(self.fileName)")
                self.phase = .failed("Checksum SHA-256 no coincide: descarga corrupta, reintenta / checksum mismatch: corrupt download, retry")
            }
        }
    }

    // MARK: - Surfacing seams (census W8, T2-3 chunk E)

    /// Census W8 Models:193 (T2-3 chunk E): the disk-space gate. Returns the
    /// free space when the download would leave too little (under the transfer
    /// plus a 1 GB margin), nil otherwise. Unknown capacity (0 — including a
    /// failed free-space read) is nil: an unreadable volume must not read as
    /// "no space" and stall the download, the gate's documented exFAT
    /// behavior. Pure so checks can pin the safe direction (D3).
    nonisolated static func capacityShortfall(available: Int64, remaining: Int64) -> Int64? {
        guard available > 0, available < remaining + 1_000_000_000 else { return nil }
        return available
    }

    /// Census W8 Models:131 (T2-3 chunk E): the English failure for a staged
    /// download whose file could not be closed after the transfer — the file
    /// may be incomplete, so this surfaces instead of any verification. Pure
    /// so checks can pin the wording (D3).
    nonisolated static func closeFailureMessage(_ error: Error, fileName: String) -> String {
        "Could not close the downloaded file \(fileName) after the transfer; it may be incomplete: \(error.localizedDescription)"
    }

    /// Census W8 Models:329 (T2-3 chunk E): whether a failed removal of the
    /// old destination blocks the checksum-verified finalize. It blocks only
    /// when a destination is actually present (the removal genuinely failed);
    /// an absent destination is the normal first-download case and stays
    /// benign. Pure so checks can pin the safe direction (D3).
    nonisolated static func finalizeBlocked(by removalError: Error?, destinationExists: Bool) -> Bool {
        removalError != nil && destinationExists
    }

    /// Census W8 Models:329 (T2-3 chunk E): the English failure when an
    /// existing destination file cannot be replaced to finish the download.
    /// Pure so checks can pin the wording (D3).
    nonisolated static func finalizeBlockerMessage(destination: String, reason: String) -> String {
        "Could not replace the existing file \(destination) to finish the download: \(reason)"
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            if let closeError = sink.close() {
                // Census W8 Models:131 (T2-3 chunk E): this path already
                // carries its own outcome (paused after a network error, or a
                // cancellation), so a failing close is logged — never a second
                // error over them. The success path leaves the close to
                // finishTransfer, which surfaces it.
                AppLog.downloads.error("Could not close \(self.fileName, privacy: .public) after the transfer error: \(closeError.localizedDescription, privacy: .public)")
            }
        }
        Task { @MainActor in
            if let error {
                if (error as NSError).code == NSURLErrorCancelled || self.phase == .paused || self.error != nil {
                    return
                }
                // Keep the partial file and resume from the stable URL.
                self.phase = .paused
                AppLog.downloads.error("download paused after network error: \(error.localizedDescription)")
                return
            }
            self.finishTransfer()
        }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var models: [LocalModel] = []
    @Published private(set) var modelGroups: [ModelFamilyGroup] = []
    @Published var downloads: [DownloadItem] = []
    private var lastRefresh = Date.distantPast
    private var refreshGeneration = 0
    private var fileIndex: ModelFileIndex?
    private var componentChecks: Set<String> = []

    /// Start the scan at launch without blocking the first frame.
    init() {
        // Keep Base selected for existing installs.
        if UserDefaults.standard.object(forKey: SettingsKeys.whisperModel) == nil {
            let legacy = whisperDirectory.appendingPathComponent("ggml-base.bin")
            if FileManager.default.fileExists(atPath: legacy.path) {
                UserDefaults.standard.set("base", forKey: SettingsKeys.whisperModel)
            }
        }
        refresh()
    }

    /// The fixed default location, used when the user hasn't picked a custom folder.
    nonisolated static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")

    /// Census W8 Models:33/:411/:449/:494 (T2-3 chunk E): the English line for
    /// a models folder (or a whisper/imagen subfolder) that could not be
    /// created before a scan or download. The caller proceeds as before — the
    /// scan then finds nothing, and a download's own open surfaces the same
    /// disk trouble — but the miss is named. Pure so checks can pin it (D3).
    nonisolated static func directoryCreationFailureNotice(directory: String, purpose: String,
                                                           reason: String) -> String {
        "Could not create \(purpose) at \(directory); continuing without it: \(reason)"
    }

    /// Where models are scanned, downloaded and deleted. Defaults to `~/models`,
    /// overridable from Settings (persisted in `SettingsKeys.modelsDir`).
    var directory: URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.modelsDir) ?? ""
        return custom.isEmpty ? Self.defaultDirectory : URL(fileURLWithPath: custom, isDirectory: true)
    }

    /// Preferred destination for image and video components and generated media.
    var imagenDirectory: URL { directory.appendingPathComponent("imagen", isDirectory: true) }

    var whisperDirectory: URL { directory.appendingPathComponent("whisper", isDirectory: true) }

    var selectedWhisperModel: WhisperModel {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.whisperModel)
            ?? WhisperModel.recommendedID
        return WhisperModel.model(id: id)
    }

    /// Census W8 Models:622/:623 (T2-3 chunk E): the English line for a failed
    /// projector lookup — no projector gets auto-paired, and why vision is
    /// unavailable is named. A repo that simply has no projector stays quiet.
    /// Pure so checks can pin it (D3).
    nonisolated static func projectorLookupFailureNotice(repo: String, reason: String) -> String {
        "Could not look up a vision projector in the \(repo) repo; no projector will be auto-paired: \(reason)"
    }

    func downloadWhisperModel(_ model: WhisperModel? = nil) {
        let model = model ?? selectedWhisperModel
        guard let remote = URL(string: model.downloadURL) else { return }
        let dir = whisperDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Census W8 Models:411 (T2-3 chunk E): the download still starts
            // (its sink open surfaces the same disk trouble moments later);
            // the missing folder is named here. T2-2 chunk B pattern.
            let notice = Self.directoryCreationFailureNotice(
                directory: dir.path, purpose: "the whisper models folder",
                reason: error.localizedDescription)
            AppLog.downloads.error("\(notice, privacy: .public)")
        }
        let destination = model.url(in: dir)
        guard !FileManager.default.fileExists(atPath: destination.path),
              !downloads.contains(where: { $0.destination == destination && $0.error == nil }) else { return }
        let item = DownloadItem(remote: remote, destination: destination)
        item.onFinish = { [weak self] in self?.objectWillChange.send() }
        downloads.append(item)
    }

    func whisperDownload(_ model: WhisperModel? = nil) -> DownloadItem? {
        let destination = (model ?? selectedWhisperModel).url(in: whisperDirectory)
        return downloads.last { $0.destination == destination && !$0.finished }
    }

    func whisperModelInstalled(_ model: WhisperModel? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (model ?? selectedWhisperModel).url(in: whisperDirectory).path)
    }

    var selectedWhisperModelURL: URL {
        selectedWhisperModel.url(in: whisperDirectory)
    }

    func retryWhisperDownload(_ item: DownloadItem) {
        let model = WhisperModel.catalog.first { $0.url(in: whisperDirectory) == item.destination }
        downloads.removeAll { $0.id == item.id }
        downloadWhisperModel(model)
    }

    var whisperVADURL: URL {
        WhisperVADModel.url(in: whisperDirectory)
    }

    var whisperVADInstalled: Bool {
        FileManager.default.fileExists(atPath: whisperVADURL.path)
    }

    func downloadWhisperVAD() {
        guard let remote = URL(string: WhisperVADModel.downloadURL) else { return }
        do {
            try FileManager.default.createDirectory(at: whisperDirectory, withIntermediateDirectories: true)
        } catch {
            // Census W8 Models:449 (T2-3 chunk E): same pattern as :411 — the
            // download still starts and the missing folder is named here.
            let notice = Self.directoryCreationFailureNotice(
                directory: whisperDirectory.path, purpose: "the whisper models folder",
                reason: error.localizedDescription)
            AppLog.downloads.error("\(notice, privacy: .public)")
        }
        guard !whisperVADInstalled,
              !downloads.contains(where: { $0.destination == whisperVADURL && $0.error == nil }) else { return }
        let item = DownloadItem(remote: remote, destination: whisperVADURL)
        item.onFinish = { [weak self] in self?.objectWillChange.send() }
        downloads.append(item)
    }

    func whisperVADDownload() -> DownloadItem? {
        downloads.last { $0.destination == whisperVADURL && !$0.finished }
    }

    func retryWhisperVADDownload(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        downloadWhisperVAD()
    }

    /// Download an image-gen component into the `imagen/` subfolder under its fixed
    /// name. Reuses the resumable transfer used for models; skips the projector
    /// auto-fetch (components aren't vision models).
    func downloadImageComponent(urlString: String, fileName: String) {
        guard let remote = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              remote.scheme?.hasPrefix("http") == true else { return }
        let dir = imagenDirectory
        let dest = dir.appendingPathComponent(fileName)
        let names = componentNames(fileName: fileName, remote: remote)
        if fileIndex?.file(namedAny: names, preferredDirectory: dir) != nil { return }
        let key = fileName.precomposedStringWithCanonicalMapping.lowercased()
        guard !componentChecks.contains(key),
              !downloads.contains(where: { $0.destination == dest && $0.error == nil }) else { return }
        componentChecks.insert(key)
        let root = directory
        // Catch files copied in after the last refresh without walking the tree
        // on the main actor or starting a duplicate transfer.
        Task { [weak self] in
            let existing = await Task.detached(priority: .utility) {
                ModelFileIndex.scan(in: root).file(namedAny: names, preferredDirectory: dir)
            }.value
            guard let self else { return }
            componentChecks.remove(key)
            guard directory.standardizedFileURL == root.standardizedFileURL else { return }
            if existing != nil {
                refresh()
                return
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                // Census W8 Models:494 (T2-3 chunk E): same pattern as :411 —
                // the component download still starts; the missing folder is
                // named here.
                let notice = Self.directoryCreationFailureNotice(
                    directory: dir.path, purpose: "the imagen components folder",
                    reason: error.localizedDescription)
                AppLog.downloads.error("\(notice, privacy: .public)")
            }
            guard !downloads.contains(where: { $0.destination == dest && $0.error == nil }) else { return }
            let item = DownloadItem(remote: remote, destination: dest)
            item.onFinish = { [weak self] in self?.refresh() }
            downloads.append(item)
        }
    }

    /// Resolves an image or video component anywhere in the models tree.
    private func componentFile(_ component: ImageGenComponent) -> URL? {
        if component.fileName.hasPrefix("/") {
            let url = URL(fileURLWithPath: component.fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let remote = URL(string: component.urlString)
        return fileIndex?.file(namedAny: componentNames(fileName: component.fileName, remote: remote),
                                preferredDirectory: imagenDirectory)
    }

    private func componentNames(fileName: String, remote: URL?) -> [String] {
        guard let sourceName = remote?.lastPathComponent, !sourceName.isEmpty,
              sourceName.caseInsensitiveCompare(fileName) != .orderedSame else { return [fileName] }
        return [fileName, sourceName]
    }

    func componentPath(_ component: ImageGenComponent) -> URL {
        componentFile(component) ?? component.path(in: imagenDirectory)
    }

    func hasComponent(_ component: ImageGenComponent) -> Bool {
        componentFile(component) != nil
    }

    /// The in-progress (or failed) download for an image component, matched inside
    /// the `imagen/` subfolder so it can show live progress on its card.
    func imageDownload(fileName: String) -> DownloadItem? {
        downloads.last {
            $0.destination.lastPathComponent == fileName
                && $0.destination.deletingLastPathComponent().lastPathComponent == "imagen"
                && !$0.finished
        }
    }

    func refresh() {
        lastRefresh = Date()
        refreshGeneration += 1
        let generation = refreshGeneration
        let directory = directory
        ModelTraitsCache.invalidate()
        ModelName.forgetCachedNames()
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                let index = ModelFileIndex.scan(in: directory)
                let models = LocalModel.models(from: index.llmFiles)
                let groups = ModelFamilyGroup.grouped(models)
                let files = Set(index.files.map(\.lastPathComponent))
                return (models, groups, files, index)
            }.value
            guard let self, generation == refreshGeneration else { return }
            models = snapshot.0
            modelGroups = snapshot.1
            presentFiles = snapshot.2
            fileIndex = snapshot.3
            ModelTraitsCache.warm(paths: snapshot.0.map(\.url.path)) { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    func refreshIfNeeded(minimumInterval: TimeInterval = 1) {
        guard Date().timeIntervalSince(lastRefresh) >= minimumInterval else { return }
        refresh()
    }

    /// Every indexed basename, including projectors and drafts filtered from the model list.
    @Published private(set) var presentFiles: Set<String> = []

    func isDownloaded(fileName: String) -> Bool {
        presentFiles.contains(fileName)
    }

    func localModel(fileName: String) -> LocalModel? {
        models.first { $0.name == fileName }
    }

    func isDownloading(fileName: String) -> Bool {
        downloads.contains { $0.fileName == fileName && !$0.finished && $0.error == nil }
    }

    /// The in-progress (or failed) download for a file, so a card can show its
    /// live progress right where the user pressed Download. Finished ones are
    /// excluded — the model then appears as a local file instead.
    func downloadItem(fileName: String) -> DownloadItem? {
        downloads.last { $0.fileName == fileName && !$0.finished }
    }

    /// Downloads `urlString` into the models folder. `preferredName`, when set,
    /// overrides the saved filename — used for multimodal projectors, which ship
    /// under generic, collision-prone names (e.g. `mmproj-F16.gguf`, identical
    /// across repos). Saving them as `<model>.mmproj.gguf` makes the model→
    /// projector pairing deterministic and avoids cross-repo filename clashes.
    func download(urlString: String, preferredName: String? = nil,
                  fetchVisionProjector: Bool = true) {
        guard let remote = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              remote.scheme?.hasPrefix("http") == true else { return }
        let fileName = preferredName ?? remote.lastPathComponent
        let dest = directory.appendingPathComponent(fileName)
        let item = DownloadItem(remote: remote, destination: dest)
        item.onFinish = { [weak self] in self?.refresh() }
        downloads.append(item)
        Self.recordSource(urlString, forFile: fileName)
        // Vision models ship a separate projector (mmproj). When downloading the
        // model, fetch its sibling mmproj too so vision works without manual steps.
        if fetchVisionProjector && !fileName.lowercased().contains("mmproj") {
            Task { await autoFetchProjector(for: remote) }
        }
    }

    /// If `modelURL` points at a Hugging Face GGUF whose repo also contains an
    /// `*mmproj*.gguf` (multimodal projector), download that projector to the same
    /// folder. No-op for non-HF URLs, non-vision repos, or when it's already local.
    func autoFetchProjector(for modelURL: URL) async {
        guard modelURL.host?.contains("huggingface.co") == true else { return }
        let comps = modelURL.pathComponents   // ["/", owner, repo, "resolve", branch, file…]
        guard let r = comps.firstIndex(of: "resolve"), r >= 2, comps.count > r + 1 else { return }
        let repo = comps[r - 2] + "/" + comps[r - 1]
        let branch = comps[r + 1]
        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(branch)") else { return }
        let data: Data
        do {
            let (fetched, _) = try await URLSession.shared.data(from: api)
            data = fetched
        } catch {
            // Census W8 Models:622 (T2-3 chunk E): a failed lookup used to be
            // indistinguishable from a repo with no projector — vision was
            // silently unavailable. No-pairing stays; the failed lookup is named.
            let notice = Self.projectorLookupFailureNotice(
                repo: repo, reason: error.localizedDescription)
            AppLog.downloads.error("\(notice, privacy: .public)")
            return
        }
        let entries: [[String: Any]]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                let notice = Self.projectorLookupFailureNotice(
                    repo: repo, reason: "the repo tree response was not a file list")
                AppLog.downloads.error("\(notice, privacy: .public)")
                return
            }
            entries = parsed
        } catch {
            let notice = Self.projectorLookupFailureNotice(
                repo: repo, reason: error.localizedDescription)
            AppLog.downloads.error("\(notice, privacy: .public)")
            return
        }
        let projectors = entries.compactMap { $0["path"] as? String }
            .filter { $0.lowercased().contains("mmproj") && $0.lowercased().hasSuffix(".gguf") }
        // Pick the best projector for Metal-on-AMD. The vision encoder runs partly
        // on CPU here, so precision barely matters: prefer the smallest sane one —
        // q8 if present, else f16 (avoid bf16, which Metal ops don't like, and f32,
        // which is twice the size for no gain). Fall back to whatever's there.
        func has(_ s: String, _ k: String) -> Bool { s.lowercased().contains(k) }
        let proj = projectors.first { has($0, "q8") }
            ?? projectors.first { has($0, "f16") && !has($0, "bf16") }
            ?? projectors.first { !has($0, "f32") && !has($0, "bf16") }
            ?? projectors.first
        guard let proj else { return }
        // Save under a model-specific name so pairing is unambiguous and projectors
        // from different repos (all named e.g. mmproj-F16.gguf) never collide.
        let modelStem = modelURL.deletingPathExtension().lastPathComponent
        let projName = "\(modelStem).mmproj.gguf"
        let projDest = directory.appendingPathComponent(projName)
        guard !FileManager.default.fileExists(atPath: projDest.path),
              !downloads.contains(where: { $0.destination == projDest && $0.error == nil }) else { return }
        download(urlString: "https://huggingface.co/\(repo)/resolve/\(branch)/\(proj)", preferredName: projName)
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.finished || $0.error != nil }
    }

    static func recordSource(_ urlString: String, forFile fileName: String) {
        var map = SettingsNumericCoercion.dictionary(SettingsKeys.modelSource) as? [String: String] ?? [:]
        map[fileName] = urlString
        UserDefaults.standard.set(map, forKey: SettingsKeys.modelSource)
    }

    static func source(forFile fileName: String) -> String? {
        (SettingsNumericCoercion.dictionary(SettingsKeys.modelSource) as? [String: String])?[fileName]
    }

    static func recordDigest(_ sha256: String, forFile fileName: String) {
        var map = SettingsNumericCoercion.dictionary(SettingsKeys.modelDigest) as? [String: String] ?? [:]
        map[fileName] = sha256.lowercased()
        UserDefaults.standard.set(map, forKey: SettingsKeys.modelDigest)
    }

    static func digest(forFile fileName: String) -> String? {
        (SettingsNumericCoercion.dictionary(SettingsKeys.modelDigest) as? [String: String])?[fileName]
    }

    /// Re-downloads every shard from its recorded source.
    func update(_ model: LocalModel) {
        for part in model.partURLs {
            let name = part.lastPathComponent
            guard let source = Self.source(forFile: name) else { continue }
            download(urlString: source, preferredName: name, fetchVisionProjector: false)
        }
    }

    /// For a local model that is a known catalog vision model whose multimodal
    /// projector isn't present in the folder, returns the catalog entry so the UI
    /// can offer to download the missing mmproj.
    func missingVisionProjector(for model: LocalModel) -> CatalogModel? {
        guard let cat = Catalog.models.first(where: { $0.fileName == model.name }), cat.isVision else { return nil }
        guard ServerSettings.mmprojPath(forModel: model.url.path) == nil else { return nil }   // already paired
        return cat
    }

    /// Download the multimodal projector for a catalog vision model into the folder.
    func downloadProjector(for cat: CatalogModel) {
        guard let url = URL(string: cat.urlString) else { return }
        Task { await autoFetchProjector(for: url) }
    }

    /// Download a DFlash draft under a model-specific name so pairing is unambiguous.
    func downloadDflashDraft(repo: String, file: String, modelStem: String) {
        let name = "\(modelStem).dflash.gguf"
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
              !downloads.contains(where: { $0.destination.lastPathComponent == name && $0.error == nil }) else { return }
        download(urlString: "https://huggingface.co/\(repo)/resolve/main/\(file)",
                 preferredName: name, fetchVisionProjector: false)
    }

    /// Retry a failed download by replacing it with a fresh transfer (new session
    /// + re-fetched metadata), reusing the same source URL.
    func retry(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        // Preserve the saved name when it was renamed (e.g. projectors), so the
        // retry lands on the same destination instead of the generic remote name.
        let remoteName = item.remote.lastPathComponent
        let preferred = item.destination.lastPathComponent == remoteName ? nil : item.destination.lastPathComponent
        download(urlString: item.remote.absoluteString, preferredName: preferred)
    }

    /// Moves the model and its paired files to the Trash.
    func delete(_ model: LocalModel) {
        for sibling in [ServerSettings.mmprojPath(forModel: model.url.path),
                        ServerSettings.dflashDraftPath(forModel: model.url.path),
                        ServerSettings.mtpDraftPath(forModel: model.url.path)].compactMap({ $0 }) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: sibling), resultingItemURL: nil)
        }
        var digests = SettingsNumericCoercion.dictionary(SettingsKeys.modelDigest) as? [String: String] ?? [:]
        for url in model.partURLs {
            digests[url.lastPathComponent] = nil
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        UserDefaults.standard.set(digests, forKey: SettingsKeys.modelDigest)
        refresh()
    }
}
