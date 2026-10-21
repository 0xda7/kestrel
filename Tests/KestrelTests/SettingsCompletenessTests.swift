// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The A2 completeness law, self-enforcing (mission T3-2, census W7-5/W7-6):
/// every `SettingsKeys` constant is either in `resettableOptionKeys` — so the
/// Reset button and the settings archive cover it — or carries an exclusion
/// comment naming resettableOptionKeys on its declaration. The law check reads
/// Sources/App/Support.swift, so a comment is not decoration: deleting one
/// turns the check RED exactly like removing a list entry does.
final class SettingsCompletenessTests: CheckCase {
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "settings-completeness-tests")
        suite.removePersistentDomain(forName: "settings-completeness-tests")
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "settings-completeness-tests")
        super.tearDown()
    }

    // MARK: Source parsing

    private struct KeyDeclaration {
        let name: String
        let commentBlock: String
    }

    /// Every `static let <name> = "…"` declaration inside the SettingsKeys
    /// block of Support.swift, each with the contiguous comment lines (and
    /// blank lines) immediately above it.
    private func settingsKeyDeclarations() -> [KeyDeclaration] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KestrelTests (the file's directory)
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // package root
        let supportURL = repoRoot.appendingPathComponent("Sources/App/Support.swift")
        guard let source = try? String(contentsOf: supportURL, encoding: .utf8),
              let start = source.range(of: "enum SettingsKeys {"),
              let end = source.range(of: "static func clearStaleLanguage"),
              start.lowerBound < end.lowerBound else {
            return []
        }
        let lines = String(source[start.upperBound..<end.lowerBound])
            .components(separatedBy: "\n")
        var declarations: [KeyDeclaration] = []
        for (index, line) in lines.enumerated() {
            guard let name = Self.declarationName(line) else { continue }
            var comments: [String] = []
            var cursor = index - 1
            while cursor >= 0 {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("//") {
                    if trimmed.hasPrefix("//") { comments.append(trimmed) }
                    cursor -= 1
                } else {
                    break
                }
            }
            declarations.append(KeyDeclaration(name: name,
                                               commentBlock: comments.joined(separator: "\n")))
        }
        return declarations
    }

    private static func declarationName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("static let "),
              let equals = trimmed.firstIndex(of: "="),
              trimmed[trimmed.index(after: equals)...]
                  .trimmingCharacters(in: .whitespaces).hasPrefix("\"") else { return nil }
        let name = trimmed[trimmed.index(trimmed.startIndex,
                                         offsetBy: "static let ".count)..<equals]
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: Checks

    /// The A2 law itself (mission T3-2): every SettingsKeys constant is in
    /// resettableOptionKeys or carries an exclusion comment. Sabotage drills:
    /// remove an entry from resettableOptionKeys, or delete an exclusion
    /// comment from any declaration — either act turns this check RED.
    func testEverySettingsKeyIsResettableOrDocumentedExcluded() {
        let declarations = settingsKeyDeclarations()
        XCTAssertGreaterThan(declarations.count, 180,
                             "the Support.swift parse went dry — the law check is reading the wrong slice")
        let listed = Set(SettingsKeys.resettableOptionKeys)
        let violations = declarations.filter { declaration in
            !listed.contains(declaration.name)
                && !declaration.commentBlock.contains("resettableOptionKeys")
        }
        XCTAssertTrue(violations.isEmpty,
                      "\(violations.count) SettingsKeys constant(s) are neither resettable nor "
                    + "documented-excluded (A2 law, census W7-5/W7-6): "
                    + violations.map(\.name).sorted().joined(separator: ", "))
    }

    /// The reset drill, durable (census V3): every key added to
    /// resettableOptionKeys in this chunk is actually cleared by the Reset
    /// path, and a documented-excluded key survives. On the pre-chunk code
    /// the three W7-5 seeds (videoVAETiling, imagenCleanupOnClose,
    /// videoNegativeSeeded) stay set after the reset — this check RED — the
    /// census's named discrimination.
    func testResetClearsTheNewlyResettableKeysAndSparesDocumentedOnes() {
        suite.set(true, forKey: SettingsKeys.videoVAETiling)
        suite.set(false, forKey: SettingsKeys.imagenCleanupOnClose)
        suite.set(true, forKey: SettingsKeys.videoNegativeSeeded)
        suite.set(44, forKey: SettingsKeys.videoFrames)
        suite.set(44, forKey: SettingsKeys.videoSteps)
        suite.set(2, forKey: SettingsKeys.videoRecipeVersion)
        suite.set("1024x576", forKey: SettingsKeys.videoSize)
        suite.set(1, forKey: SettingsKeys.videoGPU)
        suite.set("custom negative", forKey: SettingsKeys.videoNegativePrompt)
        suite.set("photo", forKey: SettingsKeys.upscalerFlavor)
        suite.set("x2", forKey: SettingsKeys.upscalerScale)
        suite.set("/tmp/up.gguf", forKey: SettingsKeys.upscalerCustomModel)
        suite.set(1.25, forKey: SettingsKeys.chatFontScale)
        suite.set(512, forKey: SettingsKeys.benchPP)
        suite.set(128, forKey: SettingsKeys.benchTG)
        suite.set(4, forKey: SettingsKeys.benchDepth)
        suite.set(Data("{}".utf8), forKey: SettingsKeys.subtitleStyle)
        suite.set(false, forKey: SettingsKeys.loadVision)
        suite.set(2048, forKey: SettingsKeys.imageMaxTokens)
        suite.set("https://hooks.example.test/kestrel", forKey: SettingsKeys.memoryArchiveHookURL)
        suite.set("{\"1\":{}}", forKey: SettingsKeys.imagenInstances)
        suite.set("{\"m\":\"auto\"}", forKey: SettingsKeys.dflashModes)
        suite.set("/tmp/models/keep-me.gguf", forKey: SettingsKeys.modelPath)

        SettingsKeys.resetOptionsToDefaults(defaults: suite)

        let newlyResettable = [SettingsKeys.videoVAETiling, SettingsKeys.imagenCleanupOnClose,
                               SettingsKeys.videoNegativeSeeded, SettingsKeys.videoFrames,
                               SettingsKeys.videoSteps, SettingsKeys.videoRecipeVersion,
                               SettingsKeys.videoSize, SettingsKeys.videoGPU,
                               SettingsKeys.videoNegativePrompt, SettingsKeys.upscalerFlavor,
                               SettingsKeys.upscalerScale, SettingsKeys.upscalerCustomModel,
                               SettingsKeys.chatFontScale, SettingsKeys.benchPP,
                               SettingsKeys.benchTG, SettingsKeys.benchDepth,
                               SettingsKeys.subtitleStyle, SettingsKeys.loadVision,
                               SettingsKeys.imageMaxTokens, SettingsKeys.memoryArchiveHookURL,
                               SettingsKeys.imagenInstances, SettingsKeys.dflashModes]
        for key in newlyResettable {
            XCTAssertNil(suite.object(forKey: key), "\(key) must be cleared by the reset")
        }
        XCTAssertEqual(suite.string(forKey: SettingsKeys.modelPath), "/tmp/models/keep-me.gguf",
                       "the documented-excluded model pick survives the reset")
    }
}

// MARK: - Generated registration (port from XCTest)
extension SettingsCompletenessTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SettingsCompletenessTests",
        instance: { SettingsCompletenessTests() },
        checks: [
            .init(name: "testEverySettingsKeyIsResettableOrDocumentedExcluded") { $0.testEverySettingsKeyIsResettableOrDocumentedExcluded() },
            .init(name: "testResetClearsTheNewlyResettableKeysAndSparesDocumentedOnes") { $0.testResetClearsTheNewlyResettableKeysAndSparesDocumentedOnes() },
        ])
}
