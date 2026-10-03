// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Strategy for retrying remote inference requests with exponential backoff.
struct InferenceRetryStrategy {
    let maxRetries: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    let jitter: Bool
    
    /// Creates a retry strategy.
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts (default: 3)
    ///   - baseDelay: Base delay in seconds for the first retry (default: 1)
    ///   - maxDelay: Maximum delay cap in seconds (default: 30)
    ///   - jitter: Whether to add random jitter to delays (default: true)
    init(maxRetries: Int = 3, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, jitter: Bool = true) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }
    
    /// Returns the delay before the next retry attempt.
    /// Uses exponential backoff: delay = min(maxDelay, baseDelay * 2^(attempt-1))
    /// Optionally adds random jitter within ±25% of the base delay.
    func delay(for attempt: Int, totalAttempts: Int) -> TimeInterval? {
        guard attempt < totalAttempts else { return nil }
        
        let exponentialDelay = baseDelay * pow(2.0, Double(attempt - 1))
        let cappedDelay = min(exponentialDelay, maxDelay)
        
        if jitter {
            let jitterFactor = 0.75 + (Double.random(in: 0...0.5) * 0.5)  // [0.75, 1.25]
            return cappedDelay * jitterFactor
        } else {
            return cappedDelay
        }
    }
}

/// Exponential backoff timer that waits between retry attempts.
actor BackoffTimer {
    let strategy: InferenceRetryStrategy
    var attempts: Int = 0
    var isComplete: Bool = false
    
    /// Waits the appropriate delay before the next retry attempt.
    /// Returns nil if max retries exceeded.
    func wait() async -> Bool? {
        if attempts >= strategy.maxRetries {
            isComplete = true
            return nil
        }
        
        let delay = strategy.delay(for: attempts + 1, totalAttempts: strategy.maxRetries)
        if let delay {
            attempts += 1
            try? await Task.sleep(for: .seconds(delay))
        }
        return true
    }
    
    func isExhausted() -> Bool {
        attempts >= strategy.maxRetries
    }
}
