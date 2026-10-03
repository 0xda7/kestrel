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
    static func get(_ account: String) -> String? { store[account] }
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
