// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension NSRegularExpression {
    /// Compiles a pattern that is a compile-time literal, for constant
    /// `NSRegularExpression` properties. The patterns passed here are
    /// checked-in strings whose syntax was verified when they were written, so
    /// compilation cannot fail at runtime; if a future edit introduces a
    /// broken pattern, the trap names it instead of a bare `try!` crashing far
    /// from the string. There is no honest fallback — a silently disabled
    /// pattern would change parsing behaviour with no signal — so failing
    /// loudly at first use is deliberate. Dynamic patterns (user or model
    /// supplied) must NOT use this: construct `NSRegularExpression` directly
    /// and handle the error, as PromptLibrary and SyntaxHighlightedCode do.
    static func literal(pattern: String,
                        options: Options = []) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            fatalError("Constant regex failed to compile: /\(pattern)/ — \(error)")
        }
    }
}
