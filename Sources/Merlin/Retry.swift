// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Error classification and bounded retry for tool execution (M7).
///
/// A flaky environment must not burn the run's turn budget: retries happen
/// inside one tool turn, with backoff between attempts, and only for faults
/// classified as transient. Model mistakes (`toolArg`) and permanent
/// failures are surfaced to the model immediately — retrying them would
/// teach the model that errors are the kernel's problem to absorb.
///
/// The sleep is injectable in both forms so checks prove the backoff
/// schedule without waiting real time.
public enum MerlinRetry {
    /// Why an operation failed, and what the kernel should do about it.
    public enum Classification: Equatable, Sendable {
        /// Environmental hiccup: safe to retry with backoff.
        case transient
        /// The tool arguments are wrong (bad path, malformed JSON, missing
        /// file). Never retried; the model must correct them.
        case toolArg
        /// Deterministic failure (missing binary, unsupported request).
        /// Never retried; the model must change its approach.
        case permanent
    }

    /// Error surfaced by tool handlers, carrying its own classification.
    public struct ToolError: Error, CustomStringConvertible {
        public let classification: Classification
        public let message: String

        public init(classification: Classification, message: String) {
            self.classification = classification
            self.message = message
        }

        public var description: String { message }
    }

    /// Retry policy per tool class. Filesystem tools are cheap and idempotent
    /// on reads; the ledger-backed tools never retry because their failure
    /// modes are argument errors.
    public struct Policy: Sendable {
        public let maxAttempts: Int
        /// Backoff before attempt N (1-based, N ≥ 2): `baseDelay * 2^(N-2)`.
        public let baseDelay: TimeInterval

        public init(maxAttempts: Int, baseDelay: TimeInterval) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
        }

        public static let `default` = Policy(maxAttempts: 3, baseDelay: 0.25)
        public static let neverRetry = Policy(maxAttempts: 1, baseDelay: 0)

        /// Policy for one tool name. Deterministic mapping, no tables to
        /// drift: reads retry, everything else (including stubs) fails fast.
        public static func forTool(_ name: String) -> Policy {
            switch name {
            case "fs_read", "fs_list", "fs_grep":
                return .default
            default:
                return .neverRetry
            }
        }
    }

    /// Classifies an arbitrary error thrown by a handler.
    public static func classify(_ error: Error) -> Classification {
        switch error {
        case let toolError as ToolError:
            return toolError.classification
        case is DecodingError:
            // Malformed JSON arguments from the model: its problem to fix.
            return .toolArg
        case let cocoa as NSError:
            // Filesystem faults: racing/unknown-resource faults heal;
            // programming and permission mistakes do not.
            switch cocoa.domain {
            case NSCocoaErrorDomain:
                // NSFileReadIncompatibleFormatError is not exposed to Swift;
                // match the transient set by raw code.
                switch cocoa.code {
                case NSFileReadUnknownError, NSFileReadCorruptFileError,
                     NSFileWriteUnknownError, 267 /* NSFileReadIncompatibleFormatError */,
                     NSFileWriteFileExistsError:
                    return .transient
                case NSFileNoSuchFileError, NSFileReadNoPermissionError,
                     NSFileWriteNoPermissionError, NSFileWriteInvalidFileNameError:
                    return .toolArg
                default:
                    return .permanent
                }
            case NSPOSIXErrorDomain:
                // errno constants are Int32; the NSError code is Int. Match
                // through explicit conversions so the switch is exhaustive
                // under Swift 6 strict typing.
                let code = Int(cocoa.code)
                switch code {
                case Int(EAGAIN), Int(EINTR), Int(ETIMEDOUT), Int(ECONNRESET):
                    return .transient
                case Int(ENOENT), Int(EACCES), Int(EPERM), Int(ENOTDIR),
                     Int(EISDIR), Int(ENAMETOOLONG):
                    return .toolArg
                default:
                    return .permanent
                }
            default:
                return .permanent
            }
        default:
            return .permanent
        }
    }

    /// Backoff delay before attempt N (1-based; attempt 1 has no delay).
    public static func backoff(policy: Policy, attempt: Int) -> TimeInterval {
        guard attempt >= 2 else { return 0 }
        let exponent = attempt - 2
        return policy.baseDelay * pow(2, Double(exponent))
    }

    /// Async form used by the tool registry: same classification and policy,
    /// with a task-yielding sleep so a backoff pause never blocks the
    /// cooperative thread pool. Cancellation during a backoff pause ends the
    /// retry loop (the pending error is thrown, as the run is being torn
    /// down anyway).
    public static func runAsync<T>(tool: String, operation: @Sendable () async throws -> T) async throws -> T {
        try await runAsync(tool: tool, operation: operation, sleep: { interval in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        })
    }

    /// Async retry core with an injectable sleeper for checks.
    public static func runAsync<T>(tool: String,
                                   operation: @Sendable () async throws -> T,
                                   sleep: @Sendable (TimeInterval) async -> Void) async throws -> T {
        let policy = Policy.forTool(tool)
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                let classification = classify(error)
                guard classification == .transient, attempt < policy.maxAttempts else {
                    throw error
                }
                // The delay precedes the UPCOMING attempt, hence attempt+1.
                await sleep(backoff(policy: policy, attempt: attempt + 1))
                attempt += 1
            }
        }
    }

    /// Runs `operation` under the tool's policy: transient failures retry
    /// with backoff (sleeping through `sleep`), everything else surfaces
    /// immediately. Retries never consume turn budget — this happens inside
    /// one tool turn.
    public static func run<T>(tool: String,
                              operation: () throws -> T,
                              sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> T {
        let policy = Policy.forTool(tool)
        var attempt = 1
        while true {
            do {
                return try operation()
            } catch {
                let classification = classify(error)
                guard classification == .transient, attempt < policy.maxAttempts else {
                    throw error
                }
                // The delay precedes the UPCOMING attempt, hence attempt+1.
                sleep(backoff(policy: policy, attempt: attempt + 1))
                attempt += 1
            }
        }
    }
}
