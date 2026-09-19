import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Latency/memory/thermal measurement store. Local only; exported as JSON on request.
public actor PerformanceMetrics {
    public static let shared = PerformanceMetrics()

    private var samples: [LatencyStage: [Double]] = [:]
    private var counters: [String: Int] = [:]
    private var peakFootprintBytes: UInt64 = 0
    private let logger: PrivacySafeLogger

    public init(logger: PrivacySafeLogger = .shared) {
        self.logger = logger
    }

    public func record(_ stage: LatencyStage, milliseconds: Double) {
        samples[stage, default: []].append(milliseconds)
        logger.log(.stageLatency(stage: stage, milliseconds: Int(milliseconds.rounded())))
    }

    public func increment(_ name: SafeLabel, by value: Int = 1) {
        counters[name.description, default: 0] += value
    }

    public func sampleMemory() {
        if let footprint = MemoryProbe.physicalFootprintBytes() {
            peakFootprintBytes = max(peakFootprintBytes, footprint)
            logger.log(.memory(
                footprintMB: Int(footprint / 1_048_576),
                availableMB: MemoryProbe.availableBytes().map { Int($0 / 1_048_576) }
            ))
        }
    }

    public func summary() -> MetricsSummary {
        var stages: [String: StageSummary] = [:]
        for (stage, values) in samples where !values.isEmpty {
            stages[stage.rawValue] = StageSummary(values: values)
        }
        return MetricsSummary(
            generatedAt: Date(),
            stages: stages,
            counters: counters,
            peakFootprintMB: Double(peakFootprintBytes) / 1_048_576,
            thermalState: ThermalProbe.current.rawValue
        )
    }

    public func reset() {
        samples.removeAll()
        counters.removeAll()
        peakFootprintBytes = 0
    }
}

public struct StageSummary: Codable, Sendable, Equatable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let min: Double
    public let max: Double
    public let mean: Double

    public init(values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        p50 = Self.percentile(sorted, 0.50)
        p95 = Self.percentile(sorted, 0.95)
        min = sorted.first ?? 0
        max = sorted.last ?? 0
        mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
    }

    /// Nearest-rank percentile on a sorted array.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank - 1))]
    }
}

public struct MetricsSummary: Codable, Sendable {
    public let generatedAt: Date
    public let stages: [String: StageSummary]
    public let counters: [String: Int]
    public let peakFootprintMB: Double
    public let thermalState: String
}

/// Process memory probes (phys_footprint is what jetsam enforces on iOS).
public enum MemoryProbe {
    public static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Remaining memory before jetsam (iOS only).
    public static func availableBytes() -> UInt64? {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return nil
        #endif
    }
}

public enum ThermalState: String, Codable, Sendable, SafeLabelConvertible {
    case nominal, fair, serious, critical
}

public enum ThermalProbe {
    public static var current: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}

public enum BatteryProbe {
    /// Battery level 0...1, or nil when unavailable (simulator, macOS).
    @MainActor
    public static func level() -> Float? {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : level
        #else
        return nil
        #endif
    }
}

/// Monotonic stopwatch for latency measurement.
public struct Stopwatch: Sendable {
    private let start: ContinuousClock.Instant

    public init() { start = ContinuousClock.now }

    public var elapsedMilliseconds: Double {
        let duration = ContinuousClock.now - start
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }
}
