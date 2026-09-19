import Foundation

/// Display formatting shared by the screens (sizes, countdowns, durations).
enum Formatting {
    /// "2.84 GB", "148 MB" (decimal units, as Settings → iPhone Storage shows them).
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// "1.2 of 2.84 GB".
    static func bytes(_ done: Int64, of total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = false
        let doneText = formatter.string(fromByteCount: max(0, done))
        return "\(doneText) of \(bytes(total))"
    }

    /// "0:42", "1:05".
    static func countdown(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "42 seconds", "1 minute 5 seconds" — for VoiceOver.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        return formatter.string(from: max(0, seconds.rounded(.up))) ?? ""
    }

    /// "About 3 min left", "Less than a minute left".
    static func timeRemaining(bytes remaining: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1, remaining > 0 else { return nil }
        let seconds = Double(remaining) / bytesPerSecond
        if seconds < 60 { return "Less than a minute left" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        guard let text = formatter.string(from: seconds) else { return nil }
        return "About \(text) left"
    }

    /// "42%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }
}
