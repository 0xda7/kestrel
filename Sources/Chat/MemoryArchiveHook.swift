import Foundation

/// Posts the turns an archive set aside to a URL the user configures, so an external index can
/// keep them. Deliveries survive a quit: each one is written to disk before it is attempted and
/// only removed once the receiver accepts it, so nothing is lost if the app closes mid-flight.
actor MemoryArchiveHook {
    static let shared = MemoryArchiveHook()

    /// The payload is ours and stays stable: one JSON object per archive.
    ///
    ///     {
    ///       "event": "memory_archive",
    ///       "delivery_id": "UUID",
    ///       "sent_at": "2026-09-06T21:14:03Z",
    ///       "conversation": { "id": "...", "title": "..." },
    ///       "range": { "from": 12, "to": 30, "note": "..." },
    ///       "messages": [ { "index": 12, "role": "user", "content": "..." } ]
    ///     }
    ///
    /// `delivery_id` is stable across retries, so a receiver can drop a duplicate it already
    /// stored rather than index the same turns twice.
    struct Payload: Codable {
        struct Conversation: Codable { let id: String; let title: String }
        struct Range: Codable { let from: Int; let to: Int; let note: String }
        struct Message: Codable { let index: Int; let role: String; let content: String }

        var event = "memory_archive"
        var delivery_id: String
        var sent_at: String
        var conversation: Conversation
        var range: Range
        var messages: [Message]
    }

    /// Declared delivery-policy bounds (T3-1, census W3-14): absent settings
    /// keys fall to these. Beyond the queue bound the oldest are dropped — a
    /// receiver that has been down for days must not fill the disk — and
    /// each delivery attempt gets the timeout before it counts as failed.
    static let declaredQueueLimit = 500
    static let declaredAttemptTimeout: TimeInterval = 15

    /// The operator's delivery policy (T3-1, census W3-14): absent key ->
    /// the declared default; a drifted String is reported and the declared
    /// default applies.
    static func queueLimit(in defaults: UserDefaults = .standard) -> Int {
        SettingsNumericCoercion.int(SettingsKeys.memoryArchiveHookQueueLimit,
                                    default: declaredQueueLimit, in: defaults)
    }

    static func attemptTimeout(in defaults: UserDefaults = .standard) -> TimeInterval {
        SettingsNumericCoercion.double(SettingsKeys.memoryArchiveHookTimeout,
                                       default: declaredAttemptTimeout, in: defaults)
    }

    private var draining = false

    private var queueDirectory: URL {
        let dir = AppSupport.directory.appendingPathComponent("memory-archive-hook", isDirectory: true)
        _ = Self.ensureQueueDirectory(dir)
        return dir
    }

    /// Census W8 MemoryArchiveHook:44 — the queue exists *for* durability, so a
    /// bootstrap that silently fails would doom every later write to fail just
    /// as silently. Internal so the check suite can pin it against temp paths.
    nonisolated static func ensureQueueDirectory(_ dir: URL) -> Bool {
        do {
            // 0700 at creation, the chat-store custody doctrine: queued
            // deliveries hold full turn bodies (0600 files via OwnerOnlyFile),
            // so the enclosing queue folder must not sit at the loose 0755
            // default — 0600-in-0700 keeps other local accounts out even if
            // the parent Application Support folder's permission drifts.
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            AppLog.chat.error("memory archive hook queue directory \(dir.path) could not be created: \(error.localizedDescription) — deliveries cannot be queued until it can be")
            return false
        }
        // Idempotent tighten on every resolve, not only at creation: a queue
        // directory that already exists at the loose default (0755 from an
        // older build or a restored backup) must not keep the invariant
        // broken either.
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            AppLog.chat.warning("memory archive hook queue directory \(dir.path) could not be tightened to owner-only (0700): \(error.localizedDescription) — queued turn bodies sit in a loose folder until it is fixed")
        }
        return true
    }

    nonisolated static var url: URL? {
        guard let raw = UserDefaults.standard.string(forKey: SettingsKeys.memoryArchiveHookURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        // KES-08: the stored Bearer token rides every delivery, so a
        // non-loopback receiver must be https — the same rule
        // InferenceRoute.normalizedURL enforces for provider endpoints. A
        // plain-http remote would send the credential in cleartext.
        guard url.scheme == "https" || InferenceRoute.insecureHosts.contains(host) else { return nil }
        return url
    }

    /// The legacy UserDefaults key as a raw string: its typed declaration
    /// retired behind this green self-retiring migration (census W7-4, T4-2
    /// chunk B) — the InferenceRoutes.legacyKeychainAccount shape. The
    /// per-migration check seeds this exact string.
    nonisolated static let legacySecretKey = "memoryArchiveHookSecret"
    /// KES-08: the receiver token rode plaintext UserDefaults — a ready-made
    /// exfiltration credential next to the endpoint it authorizes. It lives
    /// in the local secret store now; the legacy copy migrates once and is
    /// then deleted so nothing plaintext remains — but the delete lands only
    /// after the store confirms the write, so a failed store keeps the
    /// legacy copy as the only surviving token (surfaced via
    /// SupportDiagnostics) instead of destroying the secret.
    nonisolated static func receiverToken() -> String? {
        if let legacy = UserDefaults.standard.string(forKey: legacySecretKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            // Same law as Keychain.apiKey's migration: retire the legacy
            // copy only on a confirmed store.
            if LocalSecretStore.store("memory-archive-token", legacy) {
                UserDefaults.standard.removeObject(forKey: legacySecretKey)
            } else {
                SupportDiagnostics.record("memory-archive receiver token: the local secret store would not take the migration write (\(LocalSecretStore.url("memory-archive-token").path)); the legacy copy stays as the only surviving token and migrates on a later read")
            }
            return legacy
        }
        let s = LocalSecretStore.value("memory-archive-token")
        return (s?.isEmpty ?? true) ? nil : s
    }

    nonisolated static func setReceiverToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { LocalSecretStore.delete("memory-archive-token") }
        else { _ = LocalSecretStore.store("memory-archive-token", trimmed) }
    }

    private nonisolated static var secret: String? { receiverToken() }

    /// Queues one archive. Returns immediately: the chat must not wait on a receiver.
    nonisolated static func send(conversationID: String, title: String,
                                 from: Int, to: Int, note: String,
                                 messages: [(index: Int, role: String, content: String)]) {
        guard url != nil else { return }
        let payload = Payload(
            delivery_id: UUID().uuidString,
            sent_at: ISO8601DateFormatter().string(from: Date()),
            conversation: .init(id: conversationID, title: title),
            range: .init(from: from, to: to, note: note),
            messages: messages.map { .init(index: $0.index, role: $0.role, content: $0.content) })
        Task { await shared.enqueue(payload) }
    }

    /// Picks up anything left from a previous run.
    nonisolated static func resume() {
        Task { await shared.drain() }
    }

    private func enqueue(_ payload: Payload) async {
        let data: Data
        do {
            data = try JSONEncoder().encode(payload)
        } catch {
            // Census W8 :104 — an event that cannot even be encoded must leave
            // a trace naming it; the drop may never be silent.
            AppLog.chat.error("memory archive event \(payload.delivery_id) could not be encoded for the durable queue: \(error.localizedDescription) — the event is dropped")
            return
        }
        // The name carries the timestamp so the directory listing sorts into delivery order.
        let name = String(format: "%013.0f-%@.json", Date().timeIntervalSince1970 * 1000, payload.delivery_id)
        // Owner-only custody (0600) via the one atomic owner-only writer: a
        // durable delivery holds the full turn text, and a plain `.atomic`
        // write renames a default-mode temp into place — world-readable until
        // a chmod that never comes. Same writer as the chat store.
        if !OwnerOnlyFile.write(data, to: queueDirectory.appendingPathComponent(name)) {
            // Census W8 :107 — the durable write failed: the event never reaches
            // the drain loop, so this surfaced error is its only trace.
            AppLog.chat.error("memory archive event \(payload.delivery_id) could not be written to the durable queue — the event is dropped")
        }
        trim()
        await drain()
    }

    private func pending() -> [URL] { Self.pending(in: queueDirectory) }

    /// Lists queued deliveries oldest-first. Internal so the check suite can
    /// pin it against temp directories. Census W8 :113 — a listing failure
    /// makes the whole queue invisible and the drain loop starves silently.
    nonisolated static func pending(in dir: URL) -> [URL] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            AppLog.chat.error("memory archive hook queue could not be listed: \(error.localizedDescription) — queued deliveries are invisible until it can be read again")
            return []
        }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func trim() {
        let files = pending()
        let limit = Self.queueLimit()
        guard files.count > limit else { return }
        for f in files.prefix(files.count - limit) {
            do {
                try FileManager.default.removeItem(at: f)
            } catch {
                // Census W8 :122 — a trim delete that fails leaves the queue
                // over its disk bound; surface it instead of keeping the file
                // silently.
                AppLog.chat.warning("memory archive hook could not drop \(f.lastPathComponent) while trimming the queue: \(error.localizedDescription)")
            }
        }
        AppLog.chat.warning("memory archive hook queue over \(Self.queueLimit()), dropped the oldest")
    }

    /// Census W8 :135/:136 — an unreadable queue file used to be DELETED,
    /// destroying the durable event precisely when durability failed. It is
    /// now moved aside to `<name>.dead` (kept for inspection; pending() only
    /// lists `.json`, so a dead letter is never re-drunk) and only a failure
    /// to move it leaves it in place — surfaced, never deleted. Internal so
    /// the check suite can pin it.
    nonisolated static func quarantineUnreadable(_ file: URL) -> Bool {
        let dead = file.appendingPathExtension("dead")
        do {
            if FileManager.default.fileExists(atPath: dead.path) {
                try FileManager.default.removeItem(at: dead)
            }
            try FileManager.default.moveItem(at: file, to: dead)
            AppLog.chat.error("memory archive event \(file.lastPathComponent) could not be read — moved to \(dead.lastPathComponent) for inspection instead of deleting it")
            return true
        } catch {
            AppLog.chat.error("memory archive event \(file.lastPathComponent) could not be read and could not be moved aside: \(error.localizedDescription) — it is skipped this pass, never deleted")
            return false
        }
    }

    /// The next delivery to attempt, oldest-first, skipping files this drain
    /// pass already failed to quarantine — so an immovable file cannot spin
    /// the loop forever. Internal for pinning.
    nonisolated static func nextPending(in dir: URL, skipping: Set<URL>) -> URL? {
        pending(in: dir).first { !skipping.contains($0) }
    }

    /// One drain pass over the queue. Internal (not private) so the check
    /// suite can drive a full pass against a loopback receiver and pin the
    /// skip-on-failure contract (nextPending honors the skip set).
    func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        var backoff: UInt64 = 1
        var skipped: Set<URL> = []
        while let file = Self.nextPending(in: queueDirectory, skipping: skipped) {
            guard let url = Self.url else { return }   // hook turned off: leave the queue for later
            guard let data = try? Data(contentsOf: file) else {
                if Self.quarantineUnreadable(file) { continue }
                skipped.insert(file)
                continue
            }
            switch await post(data, to: url) {
            case .delivered:
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    // Census W8 :140 — a delivered file that cannot be removed
                    // is delivered AGAIN on the next pass. The receiver can
                    // drop the duplicate by delivery id, but the risk must be
                    // visible, not silent.
                    AppLog.chat.warning("memory archive event \(file.lastPathComponent) was delivered but could not be removed from the queue: \(error.localizedDescription) — the receiver may see it again (it can drop the duplicate by delivery id)")
                }
                backoff = 1
            case .rejected:
                // The receiver understood and refused it; another attempt would be refused too.
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    // Same law as the delivered arm above: an event whose file
                    // cannot be removed must leave the pass, or the loop
                    // re-POSTs it at full speed against nextPending for as
                    // long as the drain runs. One warning and a skip ends the
                    // spin; a later pass tries exactly once more.
                    AppLog.chat.warning("memory archive event \(file.lastPathComponent) was refused but could not be removed from the queue: \(error.localizedDescription) — it is skipped for the rest of this pass instead of being re-POSTed")
                    skipped.insert(file)
                }
                backoff = 1
            case .retry:
                try? await Task.sleep(for: .seconds(min(backoff, 300)))
                backoff *= 2
            }
        }
    }

    private enum Outcome { case delivered, rejected, retry }

    private func post(_ body: Data, to url: URL) async -> Outcome {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("memory_archive", forHTTPHeaderField: "X-Kestrel-Event")
        if let id = (try? JSONDecoder().decode(Payload.self, from: body))?.delivery_id {
            request.setValue(id, forHTTPHeaderField: "X-Kestrel-Delivery")
        }
        if let secret = Self.secret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.attemptTimeout()
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: return .delivered
            // 408 and 429 are the receiver asking for another try; the rest of 4xx is a refusal.
            case 408, 429:  return .retry
            case 400..<500:
                AppLog.chat.warning("memory archive hook refused a delivery with \(code), dropping it")
                return .rejected
            default:        return .retry
            }
        } catch {
            // The one URL-bearing log line: transport errors can embed the
            // full request URL, so the text passes through the shared
            // redactor (userinfo and token query values) before os_log.
            AppLog.chat.warning("memory archive hook could not deliver: \(SecretRedactor.url(error.localizedDescription))")
            return .retry
        }
    }
}
