// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Manages circuit breaker states for remote inference routes.
struct InferenceCircuitBreakerManager {
    private var breakers: [UUID: CircuitBreaker] = [:]
    private let key: String
    
    init(key: String) {
        self.key = key
    }
    
    /// Gets or creates a circuit breaker for a given route ID.
    func breaker(for routeID: UUID) -> CircuitBreaker {
        if let existing = breakers[routeID] {
            return existing
        }
        
        let breaker = CircuitBreaker(id: routeID)
        breakers[routeID] = breaker
        return breaker
    }
    
    /// Records a successful inference request.
    func recordSuccess(for routeID: UUID) {
        if let breaker = breakers[routeID] {
            breaker.recordSuccess()
        }
    }
    
    /// Records a failed inference request.
    func recordFailure(for routeID: UUID) {
        if let breaker = breakers[routeID] {
            breaker.recordFailure()
        }
    }
    
    /// Checks if a request can be attempted (circuit not open).
    func canAttempt(for routeID: UUID) -> Bool {
        let breaker = breaker(for: routeID)
        return breaker.canAttemptRequest()
    }
    
    /// Attempts a request, transitioning state if needed.
    func attempt(for routeID: UUID) -> Bool {
        let breaker = breaker(for: routeID)
        return breaker.attemptRequest()
    }
    
    /// Clears the circuit breaker for a route.
    func clear(for routeID: UUID) {
        breakers.removeValue(forKey: routeID)
    }
    
    /// Closes all circuit breakers, resetting to closed state.
    func closeAll() {
        for breaker in breakers.values {
            breaker.state = .closed
            breaker.failureCount = 0
            breaker.successCount = 0
        }
    }
    
    /// Saves the breaker states to a dictionary for persistence.
    func save() -> [UUID: CircuitBreakerState] {
        return breakers.reduce([:]) { result, pair in
            var newResult = result
            newResult[pair.key] = pair.value.state
            return newResult
        }
    }
    
    /// Restores breaker states from a dictionary.
    func restore(_ states: [UUID: CircuitBreakerState]) {
        for (routeID, state) in states {
            if let breaker = breakers[routeID] {
                breaker.state = state
            }
        }
    }
}
