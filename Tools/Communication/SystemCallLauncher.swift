#if os(iOS) && canImport(UIKit)
import UIKit

/// Opens `tel:` URLs. iOS shows its own confirmation before dialing.
public struct SystemCallLauncher: CallLaunching {
    public init() {}

    public func canPlaceCalls() async -> Bool {
        await Self.canOpenTelephone()
    }

    public func startCall(toDigits digits: String) async -> Bool {
        guard let url = CallURLBuilder.telURL(digits: digits) else { return false }
        return await Self.openURL(url)
    }

    @MainActor
    private static func canOpenTelephone() -> Bool {
        guard let probe = URL(string: "tel:") else { return false }
        return UIApplication.shared.canOpenURL(probe)
    }

    @MainActor
    static func openURL(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url, options: [:])
    }
}
#endif
