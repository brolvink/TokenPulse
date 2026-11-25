import Foundation

public enum Formatters {
    public static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.0fK", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }

    public static func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func formatCountdown(until date: Date?, from now: Date = Date()) -> String {
        guard let date else { return "Unknown reset" }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 {
            return "Resets soon"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "Resets in \(days)d \(hours)h"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else {
            return "Resets in \(max(1, minutes))m"
        }
    }

    public static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }
}

public enum LocalFileScanner {
    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Recursively collects files matching `fileExtension` modified within `maxAgeDays`, sorted newest first.
    public static func recentFiles(
        in directory: URL,
        matchingSuffix suffix: String,
        maxAgeDays: Double = 7,
        limit: Int = 200
    ) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86_400)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var matched: [(url: URL, modDate: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasSuffix(suffix) else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modDate = values.contentModificationDate,
                  modDate >= cutoff else {
                continue
            }
            matched.append((fileURL, modDate))
        }

        matched.sort { $0.modDate > $1.modDate }
        return Array(matched.prefix(limit).map(\.url))
    }

    public static func readDataIfPresent(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
