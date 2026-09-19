#if os(iOS) && canImport(UIKit)
import Core
import UIKit

/// Opens allow-listed apps with the fixed URLs from `AppURLBuilder`.
public struct SystemAppLauncher: AppLaunching {
    public init() {}

    public func open(_ app: SupportedApp, query: String?) async -> Bool {
        await Self.open(app, query: app == .maps ? query : nil)
    }

    @MainActor
    private static func open(_ app: SupportedApp, query: String?) async -> Bool {
        let url: URL?
        if app == .settings {
            url = URL(string: UIApplication.openSettingsURLString)
        } else {
            url = AppURLBuilder.url(for: app, query: query)
        }
        guard let url else { return false }
        return await UIApplication.shared.open(url, options: [:])
    }
}
#endif
