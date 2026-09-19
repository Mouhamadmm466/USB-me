import Core
import Foundation

/// Which V1 tools this device can actually perform right now (PRD §15 "iOS sandbox limits
/// control → capability registry and public APIs only"). Checked before a PendingAction is created
/// so the assistant never asks the user to confirm something the phone cannot do.
public struct CapabilityRegistry: Sendable {
    public let canSendText: @Sendable () async -> Bool
    public let canPlaceCalls: @Sendable () async -> Bool

    public init(
        canSendText: @escaping @Sendable () async -> Bool,
        canPlaceCalls: @escaping @Sendable () async -> Bool
    ) {
        self.canSendText = canSendText
        self.canPlaceCalls = canPlaceCalls
    }

    public static let allAvailable = CapabilityRegistry(canSendText: { true }, canPlaceCalls: { true })

    /// nil when the tool is available; otherwise the failure to report.
    public func unavailability(for tool: ToolID) async -> ToolFailure? {
        guard ToolCatalog.spec(for: tool).riskLevel.isSupportedInV1 else {
            return ToolFailure(tool: tool, code: .unsupported)
        }
        switch tool {
        case .composeMessage:
            return await canSendText() ? nil : ToolFailure(tool: tool, code: .notAvailableOnDevice)
        case .initiateCall:
            return await canPlaceCalls() ? nil : ToolFailure(tool: tool, code: .notAvailableOnDevice)
        default:
            return nil
        }
    }
}
