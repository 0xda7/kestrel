// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A strict JSON value tree, parsed and serialized in-process.
///
/// The harness needs exact JSON semantics in two places: `tasks.json` /
/// scripted-replay decoding (where schema drift must fail loudly) and the
/// `json_field` assertion (SCORING.md §2: strict parsing, no comments, no
/// trailing commas, booleans/strings exact, **no string↔number coercion**).
/// `JSONSerialization` cannot honor that last rule — it surfaces every
/// scalar as `NSNumber`, collapsing the `23` / `"23"` distinction the spec
/// forbids. This tree keeps kinds apart and owns the whole grammar, so the
/// harness never has to trust a lenient parser.
indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Parsing

/// Error thrown by `JSONParser` with a 1-based line for quick diagnosis.
struct JSONParseError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "JSON parse error (line \(line)): \(message)" }
}

enum JSONParser {
    /// Parses `text` as exactly one JSON value. Strict RFC 8259: whitespace
    /// is space/tab/LF/CR only; comments, trailing commas, single quotes,
    /// leading `+`, bare `.5`, leading zeros, `NaN`/`Infinity` and duplicate
    /// object keys are all rejected.
    static func parse(_ text: String) throws -> JSONValue {
        var parser = Cursor(text: text)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw parser.error("trailing content after top-level JSON value")
        }
        return value
    }

    /// Parses `text` and requires the top level to be a JSON object.
    static func parseObject(_ text: String) throws -> [String: JSONValue] {
        guard case .object(let object) = try parse(text) else {
            throw JSONParseError(message: "top-level JSON value is not an object", line: 1)
        }
        return object
    }

    struct Cursor {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1

        init(text: String) {
            self.scalars = Array(text.unicodeScalars)
        }

        var isAtEnd: Bool { index >= scalars.count }

        func error(_ message: String) -> JSONParseError {
            JSONParseError(message: message, line: line)
        }

        func peek() -> Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        mutating func advance() {
            if scalars[index] == "\n" { line += 1 }
            index += 1
        }

        mutating func skipWhitespace() {
            while let scalar = peek(), scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                advance()
            }
        }

        mutating func expect(_ scalar: Unicode.Scalar) throws {
            guard peek() == scalar else {
                throw error("expected '\(scalar)' but found \(peek().map { "'\($0)'" } ?? "end of input")")
            }
            advance()
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard let scalar = peek() else { throw error("unexpected end of input") }
            switch scalar {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expectLiteral("true"); return .bool(true)
            case "f": try expectLiteral("false"); return .bool(false)
            case "n": try expectLiteral("null"); return .null
            case "-", "0"..."9": return try parseNumber()
            default:
                throw error("unexpected character '\(scalar)'")
            }
        }

        mutating func expectLiteral(_ literal: String) throws {
            for char in literal.unicodeScalars {
                guard peek() == char else { throw error("invalid literal, expected \(literal)") }
                advance()
            }
        }

        mutating func parseObject() throws -> JSONValue {
            try expect("{")
            var object: [String: JSONValue] = [:]
            skipWhitespace()
            if peek() == "}" { advance(); return .object(object) }
            while true {
                skipWhitespace()
                guard peek() == "\"" else {
                    throw error("expected object key string, found \(peek().map { "'\($0)'" } ?? "end of input")")
                }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                let value = try parseValue()
                if object[key] != nil {
                    throw error("duplicate object key \"\(key)\"")
                }
                object[key] = value
                skipWhitespace()
                if peek() == "," {
                    advance()
                    skipWhitespace()
                    guard peek() != "}" else { throw error("trailing comma in object") }
                    continue
                }
                try expect("}")
                return .object(object)
            }
        }

        mutating func parseArray() throws -> JSONValue {
            try expect("[")
            var items: [JSONValue] = []
            skipWhitespace()
            if peek() == "]" { advance(); return .array(items) }
            while true {
                let value = try parseValue()
                items.append(value)
                skipWhitespace()
                if peek() == "," {
                    advance()
                    skipWhitespace()
                    guard peek() != "]" else { throw error("trailing comma in array") }
                    continue
                }
                try expect("]")
                return .array(items)
            }
        }

        mutating func parseString() throws -> String {
            try expect("\"")
            var result = String.UnicodeScalarView()
            while true {
                guard let scalar = peek() else { throw error("unterminated string") }
                if scalar == "\"" {
                    advance()
                    return String(result)
                }
                if scalar == "\\" {
                    advance()
                    guard let escape = peek() else { throw error("unterminated escape sequence") }
                    advance()
                    switch escape {
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    case "b": result.append("\u{8}")
                    case "f": result.append("\u{C}")
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "u": result.append(try parseUnicodeEscape())
                    default:
                        throw error("invalid escape sequence \\\(escape)")
                    }
                    continue
                }
                guard scalar.value >= 0x20 else {
                    throw error("unescaped control character in string")
                }
                result.append(scalar)
                advance()
            }
        }

        /// Reads one `\uXXXX` escape, joining surrogate pairs and rejecting
        /// lone surrogates (strict JSON requires well-formed Unicode).
        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try parseHex4()
            if (0xD800...0xDBFF).contains(high) {
                guard peek() == "\\", scalars.indices.contains(index + 1), scalars[index + 1] == "u" else {
                    throw error("lone high surrogate in \\u escape")
                }
                advance(); advance()
                let low = try parseHex4()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw error("invalid low surrogate in \\u escape pair")
                }
                let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else {
                    throw error("surrogate pair does not form a valid scalar")
                }
                return scalar
            }
            guard !(0xDC00...0xDFFF).contains(high) else {
                throw error("lone low surrogate in \\u escape")
            }
            guard let scalar = Unicode.Scalar(high) else {
                throw error("invalid Unicode scalar value in \\u escape")
            }
            return scalar
        }

        mutating func parseHex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let scalar = peek() else {
                    throw error("invalid \\u escape (expected 4 hex digits)")
                }
                // Character.hexDigitValue is unavailable on this toolchain;
                // parse ASCII hex digits manually.
                let digit: UInt32
                switch scalar {
                case "0"..."9": digit = scalar.value - 48
                case "a"..."f": digit = scalar.value - 87
                case "A"..."F": digit = scalar.value - 55
                default:
                    throw error("invalid \\u escape (expected 4 hex digits)")
                }
                value = value << 4 | digit
                advance()
            }
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            if peek() == "-" { advance() }
            // Integer part: "0" alone, or a nonzero digit followed by digits.
            guard let first = peek(), first == "0" || ("1"..."9").contains(first) else {
                throw error("invalid number")
            }
            advance()
            if first == "0", let next = peek(), ("0"..."9").contains(next) {
                throw error("leading zero in number")
            }
            while let scalar = peek(), ("0"..."9").contains(scalar) { advance() }
            if peek() == "." {
                advance()
                guard let digit = peek(), ("0"..."9").contains(digit) else {
                    throw error("number fraction requires at least one digit")
                }
                while let scalar = peek(), ("0"..."9").contains(scalar) { advance() }
            }
            if peek() == "e" || peek() == "E" {
                advance()
                if peek() == "+" || peek() == "-" { advance() }
                guard let digit = peek(), ("0"..."9").contains(digit) else {
                    throw error("number exponent requires at least one digit")
                }
                while let scalar = peek(), ("0"..."9").contains(scalar) { advance() }
            }
            let text = String(String.UnicodeScalarView(scalars[start..<index]))
            guard let value = Double(text), value.isFinite else {
                throw error("number does not convert to a finite Double: \(text)")
            }
            return .number(value)
        }
    }
}

// MARK: - Lookup and comparison

extension JSONValue {
    /// Dot-path lookup with numeric array indices: `items.0.cost` walks the
    /// `items` array's first element, then its `cost` key. Any miss (missing
    /// key, non-numeric index into an array, out-of-bounds index, descent
    /// into a scalar) returns nil — the assertion decides how to report it.
    func value(atPath path: String) -> JSONValue? {
        var current = self
        for component in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            switch current {
            case .object(let dict):
                guard let next = dict[component] else { return nil }
                current = next
            case .array(let items):
                guard !component.isEmpty, let index = Int(component),
                      index >= 0, index < items.count else { return nil }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    /// Equality with SCORING.md §2 semantics: numbers compare within
    /// `tolerance` (default 1e-9); booleans, strings, null compare exactly;
    /// arrays/objects compare element-wise; **different kinds never match** —
    /// no string↔number or bool↔number coercion.
    func matches(_ expected: JSONValue, tolerance: Double = 1e-9) -> Bool {
        switch (self, expected) {
        case (.number(let actual), .number(let expected)):
            return abs(actual - expected) <= tolerance
        case (.string(let actual), .string(let expected)):
            return actual == expected
        case (.bool(let actual), .bool(let expected)):
            return actual == expected
        case (.null, .null):
            return true
        case (.array(let actual), .array(let expected)):
            return actual.count == expected.count
                && zip(actual, expected).allSatisfy { $0.matches($1, tolerance: tolerance) }
        case (.object(let actual), .object(let expected)):
            return actual.count == expected.count
                && actual.allSatisfy { key, value in
                    expected[key].map { value.matches($0, tolerance: tolerance) } ?? false
                }
        default:
            return false
        }
    }

    /// True for a JSON number holding an integral value (used when decoding
    /// fields like `max_turns` that must be integers).
    var intValue: Int? {
        if case .number(let value) = self, value == value.rounded(), value >= Double(Int.min), value <= Double(Int.max) {
            return Int(value)
        }
        return nil
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Serializes the tree. Keys are emitted in sorted order so the same
    /// value always serializes byte-identically — this is what makes a
    /// serialized arguments object a valid *canonical* tool-call signature
    /// for repeat-failure detection. `pretty` adds two-space indentation and
    /// newlines (used for report.json); compact form is the default for
    /// signatures and assertion details.
    func serialized(pretty: Bool = false) -> String {
        var output = ""
        write(to: &output, indent: 0, pretty: pretty)
        return output
    }

    private func write(to output: inout String, indent: Int, pretty: Bool) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value): output += Self.numberText(value)
        case .string(let value): output += Self.escaped(value)
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += pretty ? "," : ", " }
                if pretty { output += "\n" + String(repeating: " ", count: (indent + 1) * 2) }
                item.write(to: &output, indent: indent + 1, pretty: pretty)
            }
            if pretty { output += "\n" + String(repeating: " ", count: indent * 2) }
            output += "]"
        case .object(let dict):
            guard !dict.isEmpty else { output += "{}"; return }
            output += "{"
            for (index, key) in dict.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: " ", count: (indent + 1) * 2) }
                output += Self.escaped(key)
                output += ": "
                dict[key]?.write(to: &output, indent: indent + 1, pretty: pretty)
            }
            if pretty { output += "\n" + String(repeating: " ", count: indent * 2) }
            output += "}"
        }
    }

    /// Renders a Double the way the rest of the harness reads it back:
    /// integral values as integers, everything else via Swift's shortest
    /// round-trip description.
    static func numberText(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15, value.magnitude <= Double(Int64.max) {
            return String(Int64(value))
        }
        return value.description
    }

    static func escaped(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{8}": output += "\\b"
            case "\u{C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }
}
