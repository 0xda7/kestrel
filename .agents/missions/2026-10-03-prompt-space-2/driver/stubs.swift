// Stubs for the behavioral driver. The REAL shipped sources (SkillsDiscovery,
// PromptLibrary, MetaPromptService, PiDelegateService, LatchDelegateService,
// InferenceRoutes) are compiled verbatim next to this file; these stubs
// replace only the app-framework types they reference. StreamBuffer is stubbed
// with the snapshot-replace contract ChatNative's pump relies on.

import Foundation

final class UserDefaults {
    static let standard = UserDefaults()
    private var storage: [String: Any] = [:]
    func string(forKey key: String) -> String? { storage[key] as? String }
    func integer(forKey key: String) -> Int { storage[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { storage[key] = value }
    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
    func data(forKey key: String) -> Data? { storage[key] as? Data }
}

enum SettingsKeys {
    static let piBinaryPath = "piBinaryPath"
    static let piPrimaryEnabled = "piPrimaryEnabled"
    static let piModel = "piModel"
    static let piProvider = "piProvider"
    static let piTimeout = "piTimeout"
    static let piThinkingLevel = "piThinkingLevel"
    static let latchBinaryPath = "latchBinaryPath"
    static let latchDelegateEnabled = "latchDelegateEnabled"
    static let latchDelegateTimeout = "latchDelegateTimeout"
    static let latchPrimaryEnabled = "latchPrimaryEnabled"
}

enum Keychain {
    private static var store: [String: String] = [:]
    /// Call counters the driver uses to prove the route-key session cache
    /// (a second resolution must not touch the Keychain again) and that
    /// existence probes never read secret data.
    nonisolated(unsafe) static var getCalls = 0
    nonisolated(unsafe) static var existsCalls = 0
    static func get(_ account: String) -> String? {
        getCalls += 1
        return store[account]
    }
    static func exists(_ account: String) -> Bool {
        existsCalls += 1
        return store[account] != nil
    }
    static func set(_ value: String, account: String) { store[account] = value }
    static func setThisDeviceOnly(_ value: String, account: String) { store[account] = value }
    static func delete(_ account: String) { store.removeValue(forKey: account) }
}

struct BuiltinToolInfo {
    init(displayName: String, name: String, writesData: Bool,
         definition: [String: Any]) throws {}
}

enum ChatToolsService {
    static func clampedToolResult(_ text: String) -> String { text }
}

struct ToolExecutionResult {
    var content: String
    var isError: Bool
}

/// Stub of the chat store's stream-error extraction (the real one lives in
/// ChatNative; the SSE protocol calls only this static).
enum ChatStore {
    nonisolated static func streamedError(from object: [String: Any]) -> String? { nil }
}

/// Verbatim shape of the shipped StreamError (ChatNative.swift:232).
struct StreamError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Stub of ChatAttachment (ChatNative.swift:16) with the members the compiled
/// sources touch (ChatDraft's Codable synthesis needs the full stored shape:
/// id/name/content plus the optional payload fields).
struct ChatAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    var mimeType: String? = nil
    var dataURI: String? = nil
    var byteCount: Int? = nil
    var durationSeconds: Double? = nil
    var videoFrameArea: Int? = nil
    var estimatedTokens: Int { max(1, content.count / 4) }
    var fenceHint: String { (name as NSString).pathExtension.lowercased() }
    var mediaKind: String? { nil }
}

/// Stubs of the parity-model types ChatStreamProtocol needs. Shapes copied
/// verbatim from ChatParityModels.swift (ChatToolCall:91, ChatTimings:36) so
/// the SSE accumulator tests exercise the real fields.
enum ChatToolCallState: String, Codable {
    case pending, awaitingPermission, running, completed, failed, denied
}

struct ChatToolCall: Identifiable, Codable, Equatable {
    var id = UUID()
    var serverID: String?
    var name: String
    var arguments: String
    var result: String?
    var state: ChatToolCallState = .pending
    var startedAt: Date?
    var finishedAt: Date?
}

struct ChatTimings: Codable, Equatable {
    var cachedTokens: Int?
    var promptTokens: Int?
    var promptMilliseconds: Double?
    var generatedTokens: Int?
    var generationMilliseconds: Double?
    var timeToFirstTokenMilliseconds: Double?

    init(cachedTokens: Int? = nil, promptTokens: Int? = nil,
         promptMilliseconds: Double? = nil, generatedTokens: Int? = nil,
         generationMilliseconds: Double? = nil) {
        self.cachedTokens = cachedTokens
        self.promptTokens = promptTokens
        self.promptMilliseconds = promptMilliseconds
        self.generatedTokens = generatedTokens
        self.generationMilliseconds = generationMilliseconds
    }

    init?(json: [String: Any]) {
        // Verbatim from the shipped ChatTimings (ChatParityModels.swift:70).
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        cachedTokens = int("cache_n")
        promptTokens = int("prompt_n")
        promptMilliseconds = double("prompt_ms")
        generatedTokens = int("predicted_n")
        generationMilliseconds = double("predicted_ms")
        if cachedTokens == nil, promptTokens == nil, generatedTokens == nil { return nil }
    }
}

/// Minimal snapshot-replace stream buffer (the ChatNative original's
/// contract: write() replaces the whole snapshot, finish() marks done,
/// take() returns and clears the latest snapshot).
final class StreamBuffer {
    private var latest: (reasoning: String, visible: String, speed: Double?)?
    private var done = false
    func write(reasoning: String, visible: String, speed: Double?) {
        latest = (reasoning, visible, speed)
    }
    func writeProgress(_ value: Any) {}
    func finish() { done = true }
    func take() -> (reasoning: String, visible: String, done: Bool)? {
        guard let snapshot = latest else { return nil }
        latest = nil
        return (snapshot.reasoning, snapshot.visible, done)
    }
    func reset() { latest = nil; done = false }
}

/// Stub of the app's bilingual localizer (PromptLibrary's SwiftUI half takes
/// it as an @EnvironmentObject; the driver only compiles against the shape).
import Combine

final class Localizer: ObservableObject {
    func t(_ es: String, _ en: String) -> String { en }
    func t(_ es: String, _ en: String, _ args: String...) -> String { en }
    func half(_ bilingual: String) -> String { bilingual }
}
