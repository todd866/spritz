import Foundation
import os

/// Aggregate operational counters only. Never accepts content or arbitrary metadata.
@MainActor
final class LocalTelemetry {
    enum Event: String, Codable, CaseIterable {
        case nativeTranscriptCaptured, refinementCycle, refinementCancel, refinementStart, refinementReady, refinementFailure, refinementChosen, refinementCopy
        case fnTap, fnHold, fnCancelled, pickerOpen, pickerCancel, insertionAttempt, tapLost, secureInputFallback
        case speechStart, speechFinish, speechCancel, speechFailure, speechInsertion, speechFocusRejected, speechPermissionRequired, speechUnavailable, speechFocusChanged, speechFocusLookupFailed, speechFocusMismatch
    }
    struct Metric: Codable { var count = 0; var timedCount = 0; var totalMs = 0.0; var maxMs = 0.0 }
    struct Archive: Codable { var schema = 1; var days: [String: [String: Metric]] = [:] }
    static let shared = LocalTelemetry(enabled: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)
    private let enabled: Bool
    let url: URL
    private(set) var archive: Archive
    private let clock: () -> Date
    private let writer = DispatchQueue(label: "Spritz.localTelemetry", qos: .utility)
    private var pending: DispatchWorkItem?
    private let diskState = OSAllocatedUnfairLock(initialState: false)
    var writeFailed: Bool { diskState.withLock { $0 } }
    private(set) var loadFailed = false
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Spritz/telemetry.json"), clock: @escaping () -> Date = Date.init, enabled: Bool = true) {
        self.url = url; self.clock = clock; self.enabled = enabled
        if enabled && FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Archive.self, from: data), saved.schema == 1 {
                archive = saved
            } else { archive = Archive(); loadFailed = true }
        } else { archive = Archive() }
    }
    func record(_ event: Event, durationMilliseconds: Double? = nil) {
        guard enabled else { return }
        let day = Int(floor(clock().timeIntervalSince1970 / 86400))
        archive.days = archive.days.filter { (Int($0.key) ?? Int.min) >= day - 89 }
        var metric = archive.days[String(day)]?[event.rawValue] ?? Metric()
        metric.count += 1
        if let ms = durationMilliseconds, ms.isFinite, ms >= 0 {
            metric.timedCount += 1; metric.totalMs += ms; metric.maxMs = max(metric.maxMs, ms)
        }
        archive.days[String(day), default: [:]][event.rawValue] = metric
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeSnapshot() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    private func writeSnapshot() {
        guard enabled, !loadFailed, let data = try? JSONEncoder().encode(archive) else { return }
        let destination = url
        let diskState = self.diskState
        writer.async {
            let failed: Bool
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                failed = false
            } catch { failed = true }
            diskState.withLock { $0 = failed }
        }
    }
    func flush() { pending?.cancel(); writeSnapshot(); writer.sync {} }
    func report() -> String {
        var lines = ["Local telemetry · UTC days · 90-day retention", "File: \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"]
        if loadFailed { lines.append("Unreadable archive preserved; collection is in memory only.") }
        if writeFailed { lines.append("Last disk write failed.") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for day in archive.days.keys.sorted(by: { (Int($0) ?? 0) > (Int($1) ?? 0) }) {
            lines.append(formatter.string(from: Date(timeIntervalSince1970: (Double(day) ?? 0) * 86400)))
            for (event, metric) in archive.days[day]!.sorted(by: { $0.key < $1.key }) {
                let timing = metric.timedCount > 0 ? String(format: " · avg %.0f ms · max %.0f ms", metric.totalMs / Double(metric.timedCount), metric.maxMs) : ""
                lines.append("  \(event): \(metric.count)\(timing)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
