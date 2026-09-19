import Foundation
import Telemetry

/// Risk classification from PRD §9. Policy is decided here, in Swift — never by the model.
public enum RiskLevel: Int, Codable, Sendable, Comparable, CaseIterable, SafeLabelConvertible {
    /// Read calendar, search contacts, search authorized files. May execute after permission.
    case readOnly = 0
    /// Create reminder / calendar event. Speak the exact interpretation and confirm.
    case reversibleLocalWrite = 1
    /// Compose message, initiate call. Always confirm; Apple's system UI confirms again.
    case externalCommunication = 2
    /// Financial, credentials, destructive or security operations. Unsupported in V1.
    case highRisk = 3

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var safeLabelText: String {
        switch self {
        case .readOnly: "risk0"
        case .reversibleLocalWrite: "risk1"
        case .externalCommunication: "risk2"
        case .highRisk: "risk3"
        }
    }

    /// Whether a spoken + visual confirmation bound to an exact PendingAction version is required.
    public var requiresConfirmation: Bool { self >= .reversibleLocalWrite }

    /// Whether V1 may execute this class of action at all.
    public var isSupportedInV1: Bool { self < .highRisk }
}
