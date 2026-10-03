// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Monitors real-time inference performance metrics.
struct InferencePerformanceMetrics {
    /// Current tokens per second.
    let tps: Double
    /// Current VRAM usage in MB.
    let vramUsedMB: Double
    /// Current GPU temperature in Celsius.
    let gpuTemperature: Double?
    /// Current prompt tokens.
    let promptTokens: Int
    /// Current generation tokens.
    let generationTokens: Int
    /// Start time of the current generation.
    let startTime: Date
    /// Total elapsed time in seconds.
    var elapsedSeconds: Double {
        Date().timeIntervalSince(startTime)
    }
    
    /// Predicted total time to completion in seconds.
    var predictedCompletionTime: Double? {
        guard tps > 0 else { return nil }
        let remainingTokens = generationTokens
        return Double(remainingTokens) / tps
    }
    
    /// Estimated remaining time in MM:SS format.
    var estimatedRemaining: String {
        guard let predicted = predictedCompletionTime else { return "—" }
        let minutes = Int(predicted / 60)
        let seconds = Int(predicted.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    /// Efficiency score: tps / max possible tps for the model size.
    /// Roughly 200 t/s per billion parameters for a 12GB GPU as a baseline.
    var efficiencyScore: Double? {
        guard let modelParamsB = ServerSettings.recalledMeasuredBench(forModel: ServerSettings.modelPath)
            ?.paramsB,
              modelParamsB > 0 else { return nil }
        let maxTPS = 200.0 * Double(modelParamsB)
        return tps / maxTPS
    }
}

/// Tracks performance metrics over time for analysis.
struct InferencePerformanceHistory: Identifiable {
    let id: UUID
    let timestamp: Date
    let metrics: InferencePerformanceMetrics
    
    init(id: UUID = UUID(), metrics: InferencePerformanceMetrics) {
        self.id = id
        self.timestamp = Date()
        self.metrics = metrics
    }
}

/// Collects and aggregates performance metrics.
final class PerformanceMonitor: ObservableObject {
    @Published var current: InferencePerformanceMetrics?
    @Published var history: [InferencePerformanceHistory] = []
    @Published var averageTPS: Double = 0
    @Published var minTPS: Double = 0
    @Published var maxTPS: Double = 0
    @Published var totalTokens: Int = 0
    
    private let sampleInterval: TimeInterval = 1.0
    
    private var lastSample: Date?
    private var tpsSamples: [Double] = []
    
    init() {
        // Initial sample
        updateCurrent()
    }
    
    /// Updates the current performance metrics.
    /// - Parameters:
    ///   - tps: Current tokens per second
    ///   - vramUsedMB: Current VRAM usage
    ///   - gpuTemperature: GPU temperature in Celsius
    ///   - promptTokens: Current prompt tokens
    ///   - generationTokens: Current generation tokens
    ///   - modelPath: Path to the model file
    func updateCurrent(
        tps: Double,
        vramUsedMB: Double,
        gpuTemperature: Double? = nil,
        promptTokens: Int = 0,
        generationTokens: Int = 0,
        modelPath: String = ""
    ) {
        let metrics = InferencePerformanceMetrics(
            tps: tps,
            vramUsedMB: vramUsedMB,
            gpuTemperature: gpuTemperature,
            promptTokens: promptTokens,
            generationTokens: generationTokens,
            startTime: Date()
        )
        
        current = metrics
        
        // Record history sample
        let historyEntry = InferencePerformanceHistory(metrics: metrics)
        history.append(historyEntry)
        
        // Keep only last 100 samples
        if history.count > 100 {
            history.removeFirst()
        }
        
        // Calculate running averages
        updateAverages()
    }
    
    private func updateAverages() {
        guard let current = current, current.tps > 0 else {
            averageTPS = 0
            return
        }
        
        let samples = tpsSamples
        if !samples.isEmpty {
            averageTPS = samples.reduce(0) { $0 + $1 } / Double(samples.count)
            minTPS = min(minTPS, samples.min() ?? 0)
            maxTPS = max(maxTPS, samples.max() ?? 0)
        }
        tpsSamples.append(current.tps)
        
        // Keep only last 100 samples for efficiency
        if tpsSamples.count > 100 {
            tpsSamples.removeFirst()
        }
    }
}
