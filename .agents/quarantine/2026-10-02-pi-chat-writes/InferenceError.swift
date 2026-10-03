// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Errors that can occur during remote inference operations.
enum InferenceError: Error, LocalizedError {
    case invalidURL(String)
    case authenticationFailed(String)
    case networkFailure(String)
    case invalidResponse(String)
    case timeout(Int)
    case serverError(Int)
    case unsupportedDialect(String)
    case modelNotFound(String)
    case requestTooLarge(Int)
    case rateLimited(Int)
    case internalError(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidURL(let url):
            return "Invalid inference route URL: \(url)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        case .networkFailure(let reason):
            return "Network connection error: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid response from inference server: \(reason)"
        case .timeout(let seconds):
            return "Request timed out after \(seconds) seconds"
        case .serverError(let code):
            return "Server error: \(code)"
        case .unsupportedDialect(let dialect):
            return "Inference dialect '\(dialect)' is not supported"
        case .modelNotFound(let model):
            return "Model '\(model)' not found on server"
        case .requestTooLarge(let tokens):
            return "Request too large: \(tokens) tokens exceeds limit"
        case .rateLimited(let retries):
            return "Rate limited. Please wait and try again (retry \(retries))"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }
}

/// Circuit breaker state for managing connection retries to external inference services.
enum CircuitBreakerState: Equatable {
    case closed  // Normal operation, all requests pass through
    case open    // Circuit is open, all requests are rejected
    case halfOpen // Half-open, test request to see if service is recovering
    
    var isClosed: Bool { self == .closed }
    var isOpen: Bool { self == .open }
    var isHalfOpen: Bool { self == .halfOpen }
}

/// Tracks circuit breaker state for a given inference route.
struct CircuitBreaker: Equatable, Identifiable {
    let id: UUID
    var state: CircuitBreakerState = .closed
    var failureCount: Int = 0
    var successCount: Int = 0
    var lastFailureTime: Date?
    var lastSuccessTime: Date?
    var maxConsecutiveFailures: Int = 5
    var minSuccessesToReset: Int = 3
    var minSuccessesForHalfOpen: Int = 2
    var failureResetWindow: TimeInterval = 300 // 5 minutes
    
    func recordSuccess() {
        failureCount = 0
        successCount += 1
        lastSuccessTime = Date()
    }
    
    func recordFailure() {
        failureCount += 1
        successCount = 0
        lastFailureTime = Date()
        
        // Open circuit after too many consecutive failures
        if failureCount >= maxConsecutiveFailures {
            state = .open
        }
    }
    
    func canAttemptRequest() -> Bool {
        switch state {
        case .closed: return true
        case .open:
            // Allow a test request after the failure reset window
            if let lastFailure = lastFailureTime,
               Date().timeIntervalSince(lastFailure) >= failureResetWindow {
                state = .halfOpen
                return true
            }
            return false
        case .halfOpen: return true
        }
    }
    
    func attemptRequest() -> Bool {
        if !canAttemptRequest() { return false }
        switch state {
        case .closed, .halfOpen:
            // On success in half-open state, track successes
            successCount += 1
            if successCount >= minSuccessesForHalfOpen {
                state = .closed
                failureCount = 0
            }
            return true
        case .open:
            // Transition to half-open after reset window
            state = .halfOpen
            return true
        }
    }
}
