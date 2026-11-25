import Foundation
import SwiftUI

public enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    public var fullName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .codex: return "Codex (OpenAI)"
        case .antigravity: return "Gemini Antigravity"
        }
    }

    public var shortCode: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        case .antigravity: return "G"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "terminal"
        case .antigravity: return "atom"
        }
    }

    public var accentRGB: UInt32 {
        switch self {
        case .claude: return 0xEF6C49
        case .codex: return 0x6657F4
        case .antigravity: return 0x279FE6
        }
    }

    public var accentColor: Color {
        Color(red: Double((accentRGB >> 16) & 255) / 255,
              green: Double((accentRGB >> 8) & 255) / 255,
              blue: Double(accentRGB & 255) / 255)
    }
}

public struct QuotaWindow: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let windowDurationSeconds: TimeInterval?
    public let isPrimary: Bool
    public internal(set) var cachedAt: Date?
    public let isEstimated: Bool

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowDurationSeconds: TimeInterval? = nil,
        isPrimary: Bool = false,
        isEstimated: Bool = false,
        cachedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.windowDurationSeconds = windowDurationSeconds
        self.isPrimary = isPrimary
        self.cachedAt = cachedAt
        self.isEstimated = isEstimated
    }

    public var remainingPercent: Double {
        max(0, min(100, 100.0 - usedPercent))
    }

    public func timeUntilReset(from now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return resetsAt.timeIntervalSince(now)
    }

    /// Fraction of the quota window that has already elapsed (0.0 to 1.0), if both duration and reset time are known.
    public func elapsedFraction(from now: Date = Date()) -> Double? {
        guard let resetsAt, let duration = windowDurationSeconds, duration > 0 else { return nil }
        let remainingTime = resetsAt.timeIntervalSince(now)
        let elapsed = duration - remainingTime
        return min(max(elapsed / duration, 0), 1)
    }
}

public struct LocalTokenSummary: Codable, Equatable, Sendable {
    public let recent5hTokens: Int
    public let recent7dTokens: Int
    public let sessionCount: Int
    public let lastActivityAt: Date?

    public init(
        recent5hTokens: Int = 0,
        recent7dTokens: Int = 0,
        sessionCount: Int = 0,
        lastActivityAt: Date? = nil
    ) {
        self.recent5hTokens = recent5hTokens
        self.recent7dTokens = recent7dTokens
        self.sessionCount = sessionCount
        self.lastActivityAt = lastActivityAt
    }
}

public enum ProviderConnectionStatus: Equatable, Codable, Sendable {
    case live
    case localOnly
    case demo
    case unavailable(String)

    public var badgeText: String {
        switch self {
        case .live: return "Live"
        case .localOnly: return "Local Logs"
        case .demo: return "Demo"
        case .unavailable: return "Unavailable"
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .live, .localOnly, .demo: return true
        case .unavailable: return false
        }
    }
}

public struct ProviderSnapshot: Identifiable, Codable, Equatable, Sendable {
    public var id: AIProviderKind { provider }
    public let provider: AIProviderKind
    public let planName: String?
    public let windows: [QuotaWindow]
    public let localTokens: LocalTokenSummary?
    public let status: ProviderConnectionStatus
    public let sourceDetail: String
    public let fetchedAt: Date
    public let isCached: Bool

    public init(
        provider: AIProviderKind,
        planName: String? = nil,
        windows: [QuotaWindow],
        localTokens: LocalTokenSummary? = nil,
        status: ProviderConnectionStatus,
        sourceDetail: String,
        fetchedAt: Date = Date(),
        isCached: Bool = false
    ) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.localTokens = localTokens
        self.status = status
        self.sourceDetail = sourceDetail
        self.fetchedAt = fetchedAt
        self.isCached = isCached
    }

    /// Primary window shown in compact views; falls back to the first window.
    public var primaryWindow: QuotaWindow? {
        windows.first(where: { $0.isPrimary }) ?? windows.first
    }

    /// The window with the lowest remaining percent (bottleneck) or primary window.
    public var limitingWindow: QuotaWindow? {
        windows.min(by: { $0.remainingPercent < $1.remainingPercent })
    }

    /// Weekly or longest-duration window, useful for spotting unused subscription value before reset.
    public var longestWindow: QuotaWindow? {
        windows.max(by: { ($0.windowDurationSeconds ?? 0) < ($1.windowDurationSeconds ?? 0) })
    }

    public var weeklyWindow: QuotaWindow? {
        let weekly = windows.filter { $0.windowDurationSeconds == 7 * 86_400 }
        return weekly.first { $0.id == "claude-7d" } ?? weekly.min { $0.remainingPercent < $1.remainingPercent }
    }

    public var shortWindow: QuotaWindow? {
        windows.filter { ($0.windowDurationSeconds ?? .infinity) <= 6 * 3_600 }
            .min { $0.remainingPercent < $1.remainingPercent }
    }

    public var shortLimitBlocksWeekly: Bool {
        weeklyWindow.map { $0.remainingPercent > 0 } == true && shortWindow?.remainingPercent == 0
    }

    public var menuBarWindow: QuotaWindow? {
        weeklyWindow ?? shortWindow ?? primaryWindow
    }

    /// Remaining percent displayed in the menu bar.
    public var menuBarRemainingPercent: Double? {
        menuBarWindow?.remainingPercent
    }
}

public struct SurplusAlert: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case surplusBeforeReset
        case unusedSubscription
        case crossProviderShift
        case lowQuota
    }

    public let id: String
    public let provider: AIProviderKind
    public let kind: Kind
    public let title: String
    public let body: String
    public let remainingPercent: Double
    public let windowLabel: String
    public let priority: Int
    public var resetsAt: Date? = nil

    var isSpendingOpportunity: Bool {
        kind == .surplusBeforeReset || kind == .unusedSubscription
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var refreshIntervalMinutes: Int
    public var surplusThresholdPercent: Double
    public var surplusLeadHours: Double
    public var enableSurplusAlerts: Bool
    public var enableImbalanceAlerts: Bool
    public var enableLowQuotaAlerts: Bool
    public var lowQuotaThresholdPercent: Double
    public var alertCooldownHours: Double
    public var showPercentagesInMenuBar: Bool
    public var showMiniBarsInMenuBar: Bool
    public var demoMode: Bool

    public init(
        refreshIntervalMinutes: Int = 5,
        surplusThresholdPercent: Double = 60,
        surplusLeadHours: Double = 24,
        enableSurplusAlerts: Bool = true,
        enableImbalanceAlerts: Bool = true,
        enableLowQuotaAlerts: Bool = false,
        lowQuotaThresholdPercent: Double = 15,
        alertCooldownHours: Double = 4,
        showPercentagesInMenuBar: Bool = false,
        showMiniBarsInMenuBar: Bool = true,
        demoMode: Bool = false
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.surplusThresholdPercent = surplusThresholdPercent
        self.surplusLeadHours = surplusLeadHours
        self.enableSurplusAlerts = enableSurplusAlerts
        self.enableImbalanceAlerts = enableImbalanceAlerts
        self.enableLowQuotaAlerts = enableLowQuotaAlerts
        self.lowQuotaThresholdPercent = lowQuotaThresholdPercent
        self.alertCooldownHours = alertCooldownHours
        self.showPercentagesInMenuBar = showPercentagesInMenuBar
        self.showMiniBarsInMenuBar = showMiniBarsInMenuBar
        self.demoMode = demoMode
    }
}
