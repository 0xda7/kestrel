// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// chatTemp and its sampling siblings are declared @AppStorage(Double/Int),
/// but a legacy writer stored them as strings: UserDefaults.double over a
/// String reads garbage and @AppStorage silently swaps in the declared
/// default, so a tuned temperature quietly stops applying. This registry is
/// the one place that knows which keys are numeric and what type they carry;
/// every write for them goes through a typed setter, and mistyped legacy
/// values are coerced (or dropped to the declared default) at migration and
/// import time.
enum SettingsNumericCoercion {
    enum Kind {
        /// Stored as Double; parsed with Double(String).
        case double
        /// Stored as Int; parsed with Int(String), falling through Double(String)
        /// so "0.5"-style values round instead of being discarded.
        case int
    }

    /// The chat sampling keys @AppStorage binds as numbers.
    static let chatSamplingKeys: [String: Kind] = [
        SettingsKeys.chatTemp: .double,
        SettingsKeys.chatTopP: .double,
        SettingsKeys.chatMinP: .double,
        SettingsKeys.chatTypicalP: .double,
        SettingsKeys.chatXTCProbability: .double,
        SettingsKeys.chatXTCThreshold: .double,
        SettingsKeys.chatDynatempRange: .double,
        SettingsKeys.chatDynatempExponent: .double,
        SettingsKeys.chatPresencePenalty: .double,
        SettingsKeys.chatFrequencyPenalty: .double,
        SettingsKeys.chatRepeatPenalty: .double,
        SettingsKeys.chatDryMultiplier: .double,
        SettingsKeys.chatDryBase: .double,
        SettingsKeys.chatTopK: .int,
        SettingsKeys.chatRepeatLastN: .int,
        SettingsKeys.chatSeed: .int,
        SettingsKeys.chatDryAllowedLength: .int,
        SettingsKeys.chatDryPenaltyLastN: .int,
        SettingsKeys.chatMaxTokens: .int,
        SettingsKeys.chatAgenticMaxTurns: .int,
        SettingsKeys.chatPasteLongTextLength: .int,
    ]

    /// What one mistyped string becomes.
    enum Coerced {
        case double(Double)
        case int(Int)
        /// Unparseable garbage: remove the key so @AppStorage applies its
        /// declared default.
        case fallBackToDefault
    }

    static func coerce(string raw: String, as kind: Kind) -> Coerced {
        switch kind {
        case .double:
            if let value = Double(raw) { return .double(value) }
        case .int:
            if let value = Int(raw) { return .int(value) }
            if let value = Double(raw) { return .int(Int(value)) }
        }
        return .fallBackToDefault
    }

    /// One-time migration: any registered key whose stored value is a String
    /// is rewritten typed; unparseable garbage is removed so @AppStorage falls
    /// back to its declared default. Returns the keys touched.
    @discardableResult
    static func migrateMistypedNumerics(in defaults: UserDefaults = .standard) -> [String] {
        var touched: [String] = []
        for (key, kind) in chatSamplingKeys {
            guard let raw = defaults.object(forKey: key) as? String else { continue }
            switch coerce(string: raw, as: kind) {
            case .double(let value): defaults.set(value, forKey: key)
            case .int(let value): defaults.set(value, forKey: key)
            case .fallBackToDefault: defaults.removeObject(forKey: key)
            }
            touched.append(key)
        }
        return touched
    }

    /// Import path: a value for a registered numeric key must never be stored
    /// as String. Returns the value to store, or nil when the value is an
    /// unparseable string for a numeric key (the caller drops it so the
    /// declared default applies).
    static func typedImportValue(_ value: Any, forKey key: String) -> Any? {
        guard let kind = chatSamplingKeys[key], let raw = value as? String else { return value }
        switch coerce(string: raw, as: kind) {
        case .double(let value): return value
        case .int(let value): return value
        case .fallBackToDefault: return nil
        }
    }
}
