import Darwin
import Foundation

public enum AntigravityQuotaFeed {
    private struct Payload: Codable {
        let quota: [String: Bucket]
    }

    private struct Bucket: Codable {
        let remainingFraction: Double?
        let resetTime: String?
        let resetInSeconds: Double?
        let disabled: Bool?

        enum CodingKeys: String, CodingKey {
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
            case resetInSeconds = "reset_in_seconds"
            case disabled
        }

        var hasFraction: Bool {
            disabled != true && remainingFraction.map { (0...1).contains($0) } == true
        }
    }

    private static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TokenPulse/antigravity-quota.json")
    }

    public static func capture(_ data: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.quota.values.contains(where: \.hasFraction) else { return }
        let destination = file
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(to: destination, options: .atomic)
    }

    @MainActor
    static func watch(_ onChange: @escaping @MainActor () -> Void) -> (any DispatchSourceFileSystemObject)? {
        let directory = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor != -1 else { return nil }
        // The CLI replaces the file atomically, so observe the containing directory.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    static func read(now: Date = Date()) -> (windows: [QuotaWindow], date: Date)? {
        let source = file
        guard let date = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let data = try? Data(contentsOf: source),
              let windows = try? windows(from: data, capturedAt: date, now: now),
              !windows.isEmpty else { return nil }
        return (windows, date)
    }

    static func windows(from data: Data, capturedAt date: Date, now: Date) throws -> [QuotaWindow] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return payload.quota.keys.sorted().compactMap { id -> QuotaWindow? in
            guard let bucket = payload.quota[id], bucket.hasFraction, let fraction = bucket.remainingFraction else { return nil }
            let reset = Formatters.parseISO8601(bucket.resetTime) ?? bucket.resetInSeconds.map { date.addingTimeInterval($0) }
            guard reset.map({ $0 > now }) ?? true else { return nil }
            let parts = id.lowercased().split(separator: "-")
            let weekly = parts.contains("weekly")
            let short = parts.contains("5h") || parts.contains("session")
            let duration: TimeInterval? = weekly ? 7 * 86_400 : (short ? 5 * 3_600 : nil)
            return QuotaWindow(id: "agy-cli-\(id)", label: id.replacingOccurrences(of: "-", with: " ").capitalized,
                               usedPercent: (1 - fraction) * 100, resetsAt: reset, windowDurationSeconds: duration)
        }
    }
}
