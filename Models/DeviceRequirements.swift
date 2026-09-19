import Foundation

// MARK: - Versions

/// Dotted numeric version ("18.0", "1.0.0"). Missing components compare as zero, so
/// "18" == "18.0" == "18.0.0". Pre-release/build suffixes ("1.2.0-beta", "1.2.0+7") are ignored.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// Components with trailing zeros removed (the canonical form used for comparison).
    public let components: [Int]

    public init?(_ string: String) {
        let core = string.trimmingCharacters(in: .whitespaces)
            .split(separator: "-", maxSplits: 1).first?
            .split(separator: "+", maxSplits: 1).first
        guard let core, !core.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let value = Int(part) else { return nil }
            parsed.append(value)
        }
        self.init(components: parsed)
    }

    public init(components: [Int]) {
        var trimmed = components
        while let last = trimmed.last, last == 0 { trimmed.removeLast() }
        self.components = trimmed
    }

    public var description: String {
        switch components.count {
        case 0: "0.0"
        case 1: "\(components[0]).0"
        default: components.map(String.init).joined(separator: ".")
        }
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// The running app's version, read once from the bundle.
public struct AppVersionInfo: Sendable, Equatable {
    /// `CFBundleShortVersionString`, nil for processes without one (tests, CLI tools).
    public let shortVersion: String?
    /// `CFBundleVersion`.
    public let buildNumber: String?

    public init(shortVersion: String?, buildNumber: String?) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
    }

    public init(bundle: Bundle) {
        self.init(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    public static var current: AppVersionInfo { AppVersionInfo(bundle: .main) }

    /// Stamped into integrity records. Any new build (not only a new marketing version) triggers
    /// a full re-hash before the next load, because runtime code that reads the files changed.
    public var integrityStamp: String {
        guard let shortVersion else { return "development" }
        return "\(shortVersion) (\(buildNumber ?? "0"))"
    }

    public var semanticVersion: SemanticVersion? { shortVersion.flatMap(SemanticVersion.init) }
}

// MARK: - Device profile and requirement checks

/// The facts a requirement check needs. Injectable so tests can model any iPhone.
public struct DeviceProfile: Sendable, Equatable {
    public enum Platform: String, Sendable {
        case iOS
        case macOS
        case other
    }

    public var platform: Platform
    /// `ProcessInfo.physicalMemory`: usable DRAM after firmware carve-outs, so an "8 GB" iPhone
    /// reports a little under 8 GiB (roughly 7.4–7.7 GiB, i.e. about 8.0–8.3 × 10^9 bytes).
    public var physicalMemoryBytes: UInt64
    public var operatingSystemVersion: SemanticVersion
    /// nil when the process has no bundle version; the app-version check is then skipped.
    public var appVersion: SemanticVersion?

    public init(platform: Platform, physicalMemoryBytes: UInt64, operatingSystemVersion: SemanticVersion, appVersion: SemanticVersion?) {
        self.platform = platform
        self.physicalMemoryBytes = physicalMemoryBytes
        self.operatingSystemVersion = operatingSystemVersion
        self.appVersion = appVersion
    }

    public static var current: DeviceProfile {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        #if os(iOS)
        let platform = Platform.iOS
        #elseif os(macOS)
        let platform = Platform.macOS
        #else
        let platform = Platform.other
        #endif
        return DeviceProfile(
            platform: platform,
            physicalMemoryBytes: info.physicalMemory,
            operatingSystemVersion: SemanticVersion(components: [os.majorVersion, os.minorVersion, os.patchVersion]),
            appVersion: AppVersionInfo.current.semanticVersion
        )
    }

    /// Decimal gigabytes (10^9 bytes).
    public var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_000_000_000 }
}

public enum DeviceRequirementIssue: Sendable, Hashable {
    /// Values in decimal gigabytes (10^9 bytes).
    case insufficientMemory(requiredGB: Double, installedGB: Double)
    case operatingSystemTooOld(required: String, installed: String)
    case appVersionTooOld(required: String, installed: String)

    /// Short, user-facing explanation.
    public var userMessage: String {
        switch self {
        case let .insufficientMemory(requiredGB, _):
            "Needs an iPhone with at least \(Int(requiredGB.rounded(.up))) GB of memory."
        case let .operatingSystemTooOld(required, _):
            "Needs iOS \(required) or later."
        case let .appVersionTooOld(required, _):
            "Update the app to version \(required) or later to use this model."
        }
    }
}

/// Typed outcome of a device requirement check.
public enum DeviceRequirementResult: Sendable, Equatable {
    case supported
    case unsupported([DeviceRequirementIssue])

    public var isSupported: Bool { self == .supported }

    public var issues: [DeviceRequirementIssue] {
        if case let .unsupported(issues) = self { return issues }
        return []
    }

    public var userMessage: String? { issues.first?.userMessage }
}

extension ModelPack {
    /// Memory is compared in decimal gigabytes: 7.5 × 10^9 bytes admits every 8 GB-class iPhone
    /// (they report ≈ 8.0 × 10^9) and rejects 6 GB-class ones (≤ 6.44 × 10^9). A binary-GiB
    /// reading of 7.5 could reject the very devices the pins target. The iOS version is only
    /// checked on iOS; the Mac development path (tests, evaluation runner) is exempt.
    public func checkRequirements(on device: DeviceProfile) -> DeviceRequirementResult {
        var issues: [DeviceRequirementIssue] = []
        let requiredBytes = minimumPhysicalMemoryGB * 1_000_000_000
        if Double(device.physicalMemoryBytes) < requiredBytes {
            let installed = (device.physicalMemoryGB * 10).rounded(.down) / 10
            issues.append(.insufficientMemory(requiredGB: minimumPhysicalMemoryGB, installedGB: installed))
        }
        if device.platform == .iOS, let required = SemanticVersion(minimumIOSVersion),
           device.operatingSystemVersion < required {
            issues.append(.operatingSystemTooOld(required: minimumIOSVersion, installed: device.operatingSystemVersion.description))
        }
        if let installed = device.appVersion, let required = SemanticVersion(minimumAppVersion), installed < required {
            issues.append(.appVersionTooOld(required: minimumAppVersion, installed: installed.description))
        }
        return issues.isEmpty ? .supported : .unsupported(issues)
    }
}

extension ModelManifest {
    /// Union of every pack's issues (deduplicated, in manifest order).
    public func checkRequirements(on device: DeviceProfile) -> DeviceRequirementResult {
        var issues: [DeviceRequirementIssue] = []
        for pack in packs {
            for issue in pack.checkRequirements(on: device).issues where !issues.contains(issue) {
                issues.append(issue)
            }
        }
        return issues.isEmpty ? .supported : .unsupported(issues)
    }
}
