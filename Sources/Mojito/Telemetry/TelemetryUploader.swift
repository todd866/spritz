import Foundation

/// Compatibility shell for the upstream telemetry call sites.
///
/// The public fork never records or uploads usage telemetry. The date and
/// usage helpers remain available for source-compatible tests; the upload
/// entry point is an unconditional no-op.
@MainActor
final class TelemetryUploader {
    static let shared = TelemetryUploader()
    private init() {}

    nonisolated static func utcDay(_ now: Date = Date()) -> Int {
        Int(now.timeIntervalSince1970 / 86_400)
    }

    func uploadIfDue() {}

    nonisolated static func usageFlags(lastUploadDay: Int, today: Int) -> [String: Bool] {
        let isNew = lastUploadDay <= 0
        return [
            "new": isNew,
            "weekly": isNew || utcWeek(lastUploadDay) != utcWeek(today),
            "monthly": isNew || utcMonth(lastUploadDay) != utcMonth(today),
        ]
    }

    /// Day 0 (1970-01-01) was a Thursday; the +3 puts week boundaries on Mondays.
    nonisolated static func utcWeek(_ day: Int) -> Int { (day + 3) / 7 }

    nonisolated static func utcMonth(_ day: Int) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents(
            [.year, .month],
            from: Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        )
        return c.year! * 12 + c.month!
    }
}
