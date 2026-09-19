import Core
import Foundation

/// Opens one of the allow-listed apps through a fixed, Swift-owned URL.
public protocol AppLaunching: Sendable {
    /// `query` is honored for Maps only.
    func open(_ app: SupportedApp, query: String?) async -> Bool
}

/// Pure construction of the allow-listed app URLs. The model only ever picks a `SupportedApp`
/// case; the only free text that can reach a URL is a sanitized, strictly percent-encoded Maps
/// search query.
public enum AppURLBuilder {
    public static let maxQueryLength = 80
    /// Value of `UIApplication.openSettingsURLString` (asserted in the iOS launcher).
    public static let settingsURLString = "app-settings:"

    /// RFC 3986 unreserved characters (ASCII only); everything else is percent-encoded.
    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    /// Trims, removes control/invisible characters, collapses whitespace and caps the length at
    /// 80 characters (on a word boundary when possible). Nil when nothing is left.
    public static func sanitizedQuery(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var cleaned = TextSanitizer.clean(raw, allowNewlines: false)
        if cleaned.count > maxQueryLength {
            let prefix = cleaned.prefix(maxQueryLength)
            if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) >= maxQueryLength / 2 {
                cleaned = String(prefix[..<space])
            } else {
                cleaned = String(prefix)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func percentEncoded(_ query: String) -> String {
        query.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    /// The fixed URL for `app`. A query is used for Maps only and ignored for every other app.
    public static func url(for app: SupportedApp, query: String?) -> URL? {
        switch app {
        case .maps:
            if let query = sanitizedQuery(query) {
                return URL(string: "https://maps.apple.com/?q=" + percentEncoded(query))
            }
            return URL(string: "maps://")
        case .music: return URL(string: "music://")
        case .messages: return URL(string: "sms:")
        case .mail: return URL(string: "message://")
        case .calendar: return URL(string: "calshow://")
        case .settings: return URL(string: settingsURLString)
        case .appStore: return URL(string: "itms-apps://apps.apple.com")
        case .shortcuts: return URL(string: "shortcuts://")
        }
    }
}
