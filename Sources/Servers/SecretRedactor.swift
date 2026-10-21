// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The ONE secret-redaction implementation for everything that leaves this
/// app as a log line or an export file: argv (`--api-key` pairs), environment
/// (user-typed KEY=VALUE credential tokens), and URLs (userinfo and
/// credential-bearing query parameters). Parallel copies are forbidden: the
/// startup banner, the shareable diagnostics export and the os_log surfaces
/// all call into this type, so a masking rule improved once improves every
/// surface at once (KES-03). Deliberately unrelated to Surgical/DeIdentifier,
/// which de-identifies PHI in user documents — that is a document tool, not
/// a log/export secret masker.
enum SecretRedactor {
    static let mask = "***"

    // MARK: argv

    /// Masks the value of every `--api-key <secret>` pair, in both the
    /// `--api-key X` and `--api-key=X` spellings, so logs and diagnostics
    /// can carry the full launch line without leaking the key (KES-03).
    /// A trailing `--api-key` with no value is kept as-is (there is nothing
    /// to mask). Pure so the masking contract is unit-testable; this is the
    /// former `ServerController.redactArguments`, moved here so no second
    /// copy exists.
    static func arguments(_ items: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(items.count)
        var i = 0
        while i < items.count {
            let token = items[i]
            if token == "--api-key", i + 1 < items.count {
                out += [token, mask]
                i += 2
                continue
            }
            if token.hasPrefix("--api-key=") {
                out.append("--api-key=" + mask)
                i += 1
                continue
            }
            out.append(token)
            i += 1
        }
        return out
    }

    // MARK: environment

    /// One `KEY=VALUE`-per-key line for the startup banner: app-set engine
    /// vars keep their values (they carry no secrets), while user-typed
    /// tokens from the free-form Extra-arguments field ("OPENAI_API_KEY=sk-…")
    /// are credentials and show their NAMES only (KES-03). Keys the app
    /// neither set nor was handed are omitted entirely, exactly as the
    /// banner always did — nothing else from the inherited environment is
    /// pulled into a shared log.
    static func environmentLine(environment: [String: String],
                                appSetKeys: [String],
                                userKeys: [String]) -> String {
        let appSet = Set(appSetKeys)
        let valueParts = appSetKeys.compactMap { key in
            environment[key].map { "\(key)=\($0)" }
        }
        let maskedParts = Set(userKeys).subtracting(appSet)
            .intersection(environment.keys)
            .sorted()
            .map { "\($0)=\(mask)" }
        return (valueParts + maskedParts).joined(separator: " ")
    }

    // MARK: URLs / free text

    /// Masks URL credentials in free text: `user:pass@` userinfo and the
    /// values of credential-bearing query parameters (`?token=…`,
    /// `&api_key=…`, `secret`, `password`, `auth`, …). Text without URL
    /// credentials passes through unchanged. Applied to anything bound for
    /// a log or an export — error descriptions can embed the full request
    /// URL, token included.
    static func url(_ text: String,
                    userInfoPattern: String = #"(?<=//)[^/\s:@]+:[^/\s@]+@"#,
                    querySecretPattern: String = #"(?i)([?&][A-Za-z0-9_-]*(?:key|token|secret|password|passwd|credential|auth)[A-Za-z0-9_-]*=)[^&#\s]*"#) -> String {
        guard let userInfoRegex = try? NSRegularExpression(pattern: userInfoPattern),
              let querySecretRegex = try? NSRegularExpression(pattern: querySecretPattern) else {
            // Fail closed (KES-03): a broken masker never passes secrets
            // through — the mask alone leaves instead of the original text.
            return mask
        }
        let full = NSRange(text.startIndex..., in: text)
        let maskedUserInfo = userInfoRegex.stringByReplacingMatches(
            in: text, options: [], range: full, withTemplate: "***@")
        return querySecretRegex.stringByReplacingMatches(
            in: maskedUserInfo, options: [], range: NSRange(maskedUserInfo.startIndex..., in: maskedUserInfo),
            withTemplate: "$1***")
    }
}
