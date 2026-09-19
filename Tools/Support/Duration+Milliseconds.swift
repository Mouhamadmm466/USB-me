import Foundation

extension Duration {
    /// Whole milliseconds, for latency telemetry.
    var wholeMilliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
