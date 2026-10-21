// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import KestrelCore

/// The SettingsKeys usage lint, self-enforcing (mission T4-1 H1, census
/// W7-1): every constant declared in `enum SettingsKeys` must be used
/// somewhere in Sources/ — a qualified `SettingsKeys.<name>` reference, or
/// membership in `resettableOptionKeys` (a genuine dynamic read path: the
/// Reset button and the settings archive iterate that list). Declaring a
/// key nobody reads turns this check RED, so `benchAdvanced`-class debt
/// (census W7-1: declared 2026-10, never read, never written) can never
/// land again silently.
final class SettingsUsageLintTests: CheckCase {

    // MARK: Source parsing

    private struct KeyDeclaration {
        let name: String
        let value: String
    }

    /// Every `static let <name> = "…"` declaration inside the SettingsKeys
    /// block of Support.swift (same slice the A2 completeness law reads).
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
        let block = String(source[start.upperBound..<end.lowerBound])
        var declarations: [KeyDeclaration] = []
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("static let "),
                  let equals = trimmed.firstIndex(of: "="),
                  trimmed[trimmed.index(after: equals)...]
                      .trimmingCharacters(in: .whitespaces).hasPrefix("\""),
                  let value = trimmed[trimmed.index(after: equals)...]
                      .split(separator: "\"").first else { continue }
            let name = trimmed[trimmed.index(trimmed.startIndex,
                                             offsetBy: "static let ".count)..<equals]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            declarations.append(KeyDeclaration(name: name, value: String(value)))
        }
        return declarations
    }

    /// The concatenated text of every .swift file under Sources/ — the
    /// surface a declared key must be read from at least once.
    private func sourcesText() -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return "" }
        var text = ""
        for case let url as URL in enumerator {
            guard url.pathExtension == "swift",
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text += "\n" + content
        }
        return text
    }

    /// Count of qualified `SettingsKeys.<name>` references in Sources/.
    /// The word boundary keeps prefix-named keys honest: `imagen` never
    /// counts as a use of `imagenPrompt`.
    private static func qualifiedUses(of name: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "SettingsKeys\\.\(name)\\b") else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    // MARK: Checks

    /// The lint itself (mission T4-1 H1): every declared constant is read
    /// somewhere in Sources/ — qualified reference, or the reset+archive
    /// list. Sabotage drill: declare `static let usageLintDrill =
    /// "usageLintDrill"` in SettingsKeys → this check goes RED naming it.
    /// Pre-chunk, the same check RED on `benchAdvanced` (zero uses), which
    /// this chunk deletes — the census's named discrimination.
    func testEveryDeclaredSettingsKeyIsUsedSomewhere() {
        let declarations = settingsKeyDeclarations()
        XCTAssertGreaterThan(declarations.count, 180,
                             "the Support.swift parse went dry — the usage lint is reading the wrong slice")
        let text = sourcesText()
        XCTAssertGreaterThan(text.count, 100_000,
                             "the Sources/ scan went dry — the usage lint is scanning nothing")
        let resettable = Set(SettingsKeys.resettableOptionKeys)
        let unread = declarations.filter { declaration in
            Self.qualifiedUses(of: declaration.name, in: text) == 0
                && !resettable.contains(declaration.value)
        }
        XCTAssertTrue(unread.isEmpty,
                      "\(unread.count) SettingsKeys constant(s) are declared but never read in "
                    + "Sources/ (usage lint, census W7-1): "
                    + unread.map(\.name).sorted().joined(separator: ", "))
    }
}

// MARK: - Generated registration (port from XCTest)
extension SettingsUsageLintTests {
    @MainActor static let __checkSet = CheckSet(
        suite: "SettingsUsageLintTests",
        instance: { SettingsUsageLintTests() },
        checks: [
            .init(name: "testEveryDeclaredSettingsKeyIsUsedSomewhere") { $0.testEveryDeclaredSettingsKeyIsUsedSomewhere() },
        ])
}
