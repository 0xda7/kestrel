// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// App localization.
///
/// English is the product language (operator directive 2026-10-14): UI
/// strings are written inline at every call site as `loc.t("es", "en")`
/// and the English half always wins — the Settings picker is gone, a
/// stored "es" is ignored (and cleared at launch). The Spanish halves stay
/// in the call sites for content that still carries both (catalog details,
/// relative dates, bilingual engine diagnostics picked by `half`).
final class Localizer: ObservableObject {
    @Published private(set) var language: String = "en"

    /// Kept for the many call sites that pick Spanish vs. English content
    /// directly (catalog details, relative dates). Always false while the
    /// product language is English, so those sites resolve to English.
    var isSpanish: Bool { language == "es" }

    /// Engine diagnostics are built where no Localizer exists, so they carry both
    /// halves separated by " / ". Pick one instead of showing the pair.
    func half(_ bilingual: String) -> String {
        guard let r = bilingual.range(of: " / ") else { return bilingual }
        return String(isSpanish ? bilingual[..<r.lowerBound] : bilingual[r.upperBound...])
    }

    /// Returns the string for the active language — always the English half.
    func t(_ es: String, _ en: String) -> String { en }

    /// Same lookup for a string carrying values: the `%@` placeholders are
    /// filled in after the (English) text is chosen.
    func t(_ es: String, _ en: String, _ args: String...) -> String {
        var out = t(es, en)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }
}
