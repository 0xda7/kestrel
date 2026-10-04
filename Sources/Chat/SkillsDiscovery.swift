// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Model

/// One Claude-format skill found on disk: a `SKILL.md` whose frontmatter
/// names and describes it. `path` points at the `SKILL.md` itself so a
/// caller can load the body later. Read-only discovery — skills live in the
/// operator's own folders; Kestrel only surfaces them.
struct DiscoveredSkill: Equatable {
    let name: String
    let description: String
    let path: String
}

// MARK: - Discovery

/// Skills discovery (llm-space convention, mirrored into Kestrel): scan the
/// well-known agent-skills folders one level deep and read each subfolder's
/// `SKILL.md` frontmatter. Everything here is tolerant by design — a missing
/// folder, a missing or unreadable `SKILL.md`, or malformed frontmatter just
/// means that subfolder is skipped, never a failed scan. Foundation only; the
/// Prompt Space sheet renders the list.
enum SkillsDiscovery {
    /// Folders scanned for `<subfolder>/SKILL.md`, in priority order, with
    /// `~` expanded to absolute paths. The pi agent tree leads so an
    /// operator-curated skill wins over the generic agent conventions;
    /// Kestrel's own Application Support folder comes last.
    static var discoveryPaths: [String] {
        let home = NSHomeDirectory() as NSString
        // Same base as PromptLibrary's store (Application Support with a
        // home-relative fallback), so the two stay in one place on disk.
        let appSupport = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory() + "/Library/Application Support"
        return [
            home.appendingPathComponent(".pi/agent/skills"),
            home.appendingPathComponent(".claude/skills"),
            home.appendingPathComponent(".codex/skills"),
            home.appendingPathComponent(".agents/skills"),
            (appSupport as NSString).appendingPathComponent("Kestrel/skills"),
        ]
    }

    /// Scans every discovery path one level deep: each direct subfolder's
    /// `SKILL.md` yields a skill from its frontmatter (`name`, `description`).
    /// Deterministic: paths in `discoveryPaths` order, subfolders sorted by
    /// name within each path. Same-named skills dedupe, first found wins.
    static func scan() -> [DiscoveredSkill] {
        let fileManager = FileManager.default
        var seenNames = Set<String>()
        var skills: [DiscoveredSkill] = []
        for folderRoot in discoveryPaths {
            let entries = ((try? fileManager.contentsOfDirectory(atPath: folderRoot)) ?? [])
                .sorted()
            for entry in entries {
                let folder = (folderRoot as NSString).appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: folder, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let skillFile = (folder as NSString).appendingPathComponent("SKILL.md")
                guard let markdown = try? String(contentsOfFile: skillFile, encoding: .utf8),
                      let frontmatter = parseFrontmatter(markdown) else { continue }
                // No (or empty) `name:` falls back to the folder name, which
                // is how Claude-format skills are addressed anyway.
                let name = frontmatter.name.flatMap { $0.isEmpty ? nil : $0 } ?? entry
                guard seenNames.insert(name).inserted else { continue }
                skills.append(DiscoveredSkill(name: name,
                                              description: frontmatter.description ?? "",
                                              path: skillFile))
            }
        }
        return skills
    }

    /// One `- **name** — description` line per skill, capped at `maxSkills`
    /// (a cap of zero or less yields nothing). Empty string when no skills
    /// were found, so callers can drop the section outright.
    static func markdownList(maxSkills: Int) -> String {
        guard maxSkills > 0 else { return "" }
        return scan().prefix(maxSkills)
            .map { "- **\($0.name)** — \($0.description)" }
            .joined(separator: "\n")
    }

    // MARK: Frontmatter

    /// Parses the frontmatter between leading `---` fences: only the `name`
    /// and `description` scalar keys, first occurrence wins. Values may be
    /// quoted, plain, or a YAML block scalar (`>` folded or `|` literal with
    /// optional chomping indicator) — the folded form is how real Claude-format
    /// skills write long descriptions. Returns nil when the text does not
    /// start with a `---` fence or the opening fence is never closed
    /// (body-only markdown, truncated file) so the subfolder is skipped; keys
    /// are individually optional so a missing `name` can fall back to the
    /// folder name at the call site.
    private static func parseFrontmatter(_ text: String)
        -> (name: String?, description: String?)? {
        // Editors saving UTF-8 with a BOM leave U+FEFF on the first line,
        // where whitespace-trimming does not remove it and the fence check
        // would fail — the whole skill would be silently skipped.
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: \.isNewline)
        var index = 0
        while index < lines.count,
              String(lines[index]).trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        guard index < lines.count, isFence(lines[index]) else { return nil }
        index += 1
        var closed = false
        var name: String?
        var description: String?
        while index < lines.count {
            let line = lines[index]
            index += 1
            if isFence(line) { closed = true; break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let value: String
            if let folds = blockScalarHeader(rest) {
                value = blockBody(from: &index, in: lines,
                                  separator: folds ? " " : "\n")
            } else {
                value = unquote(rest)
            }
            switch key {
            case "name":
                if name == nil { name = value }
            case "description":
                if description == nil { description = value }
            default:
                break
            }
        }
        guard closed else { return nil }
        return (name, description)
    }

    /// Recognizes a YAML block-scalar header in the value position: `>` or
    /// `|`, optionally followed by chomping (`-`, `+`) and an indentation
    /// digit. Returns true for folded blocks (`>`, lines join with spaces)
    /// and false for literal ones (`|`, lines join with newlines); nil means
    /// the value is an ordinary scalar.
    private static func blockScalarHeader(_ value: String) -> Bool? {
        var rest = Substring(value)
        guard let marker = rest.first, marker == ">" || marker == "|"
        else { return nil }
        rest = rest.dropFirst()
        while let next = rest.first, next == "-" || next == "+" || next.isNumber {
            rest = rest.dropFirst()
        }
        guard rest.isEmpty else { return nil }
        return marker == ">"
    }

    /// Consumes a block scalar's continuation lines — every following line
    /// that is blank or indented — joining their trimmed content with
    /// `separator`. Blank lines carry no content (chomping is clipped), which
    /// flattens folded multi-paragraph descriptions into one line.
    private static func blockBody(from index: inout Int, in lines: [Substring],
                                  separator: String) -> String {
        var parts: [String] = []
        while index < lines.count {
            let line = String(lines[index])
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            guard line.first == " " || line.first == "\t" else { break }
            parts.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return parts.joined(separator: separator)
    }

    /// A YAML document fence: a line that is exactly `---` (ignoring
    /// surrounding whitespace, so CRLF endings and stray spaces pass).
    private static func isFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "---"
    }

    /// Strips one pair of matching double or single quotes from a scalar
    /// value; plain values pass through untouched. Content inside the quotes
    /// is kept verbatim (no YAML escape sequences — this parser stays
    /// deliberately dumber than a YAML implementation).
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
