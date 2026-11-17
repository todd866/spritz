import Foundation
import Testing
@testable import Mojito

@MainActor struct LocalTelemetryTests {
    @Test func persistsUTCAndPrunes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("telemetry.json")
        var now = Date(timeIntervalSince1970: 86400 * 20000)
        let metrics = LocalTelemetry(url: url, clock: { now })
        metrics.record(.fnTap); metrics.record(.speechFinish, durationMilliseconds: 120)
        metrics.flush()
        #expect(LocalTelemetry(url: url).archive.days["20000"]?["fnTap"]?.count == 1)
        now.addTimeInterval(86400 * 89); metrics.record(.fnHold)
        #expect(metrics.archive.days["20000"] != nil)
        now.addTimeInterval(86400); metrics.record(.fnTap); metrics.flush()
        #expect(metrics.archive.days["20000"] == nil)
        #expect(LocalTelemetry(url: url).archive.days["20090"]?["fnTap"]?.count == 1)
    }
    @Test func writeFailureIsVisibleImmediatelyAfterFlush() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a folder".utf8).write(to: folder)
        let metrics = LocalTelemetry(url: folder.appendingPathComponent("telemetry.json"))
        metrics.record(.fnTap); metrics.flush()
        #expect(metrics.writeFailed)
        #expect(metrics.report().contains("Last disk write failed"))
    }
    @Test func corruptArchivePreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("telemetry.json")
        let bad = Data("broken".utf8); try bad.write(to: url)
        let metrics = LocalTelemetry(url: url); metrics.record(.fnTap); metrics.flush()
        #expect(metrics.loadFailed); #expect(try Data(contentsOf: url) == bad)
    }
    @Test func durationsRejectInvalidNumbersAndWritesStayOrdered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("telemetry.json")
        let metrics = LocalTelemetry(url: url, clock: { Date(timeIntervalSince1970: 0) })
        metrics.record(.speechFinish, durationMilliseconds: .nan); metrics.flush()
        metrics.record(.speechFinish, durationMilliseconds: 80); metrics.flush()
        metrics.record(.speechFinish, durationMilliseconds: 120); metrics.flush()
        let saved = LocalTelemetry(url: url).archive.days["0"]?["speechFinish"]
        #expect(saved?.count == 3); #expect(saved?.timedCount == 2); #expect(saved?.totalMs == 200)
    }
}
