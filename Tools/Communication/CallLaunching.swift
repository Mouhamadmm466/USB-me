import Core
import Foundation

/// Opens the system call flow. iOS shows its own call confirmation.
public protocol CallLaunching: Sendable {
    func canPlaceCalls() async -> Bool
    /// `digits`: an optional leading "+" then 3–20 ASCII digits, from a native contact or a
    /// transcript-verified dictation (never raw model text).
    func startCall(toDigits digits: String) async -> Bool
}

/// Builds `tel:` URLs from validated digits only.
public enum CallURLBuilder {
    public static func telURL(digits: String) -> URL? {
        let body = digits.hasPrefix("+") ? digits.dropFirst() : Substring(digits)
        guard (PhoneNumbers.minimumDigits...PhoneNumbers.maximumDigits).contains(body.count),
              body.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "tel:" + digits)
    }
}
