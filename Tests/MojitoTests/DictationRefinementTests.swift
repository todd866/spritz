import Foundation
import Testing
@testable import Mojito

struct DictationRefinementTests {
    @Test func receiptRequiresExactTextAndCaret() {
        let receipt = DictationReceipt.capture(value: "Hi 👩🏽‍💻 café", selection: NSRange(location: 15, length: 0), text: "👩🏽‍💻 café")
        #expect(receipt != nil)
        #expect(receipt?.matches(value: "Hi 👩🏽‍💻 café", selection: NSRange(location: 15, length: 0)) == true)
        #expect(receipt?.matches(value: "Hi 👩🏽‍💻 cafe", selection: NSRange(location: 15, length: 0)) == false)
        #expect(receipt?.matches(value: "Hi 👩🏽‍💻 café", selection: NSRange(location: 14, length: 0)) == false)
        #expect(DictationReceipt.capture(value: "other", selection: NSRange(location: 5, length: 0), text: "speech") == nil)
        #expect(DictationReceipt.capture(value: "speech", selection: NSRange(location: 0, length: 6), text: "speech") == nil)
        #expect(DictationReceipt.capture(value: "speech", selection: NSRange(location: Int.max, length: 0), text: "speech") == nil)
    }
    @Test func receiptRejectsChangesElsewhereInField() {
        let receipt = DictationReceipt.capture(value: "Before. Speech.", selection: NSRange(location: 15, length: 0), text: "Speech.")
        #expect(receipt != nil)
        #expect(receipt?.matches(value: "After!. Speech.", selection: NSRange(location: 15, length: 0)) == false)
    }
    @Test func acceptsOnlyStructuredModelOutput() throws {
        let result = #"{"cleaned":"Hello.","clearer":"Hello there."}"#
        let item: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": result]]
        let data = try JSONSerialization.data(withJSONObject: item)
        #expect(RefinementResult.parse(data, provider: .codex) == RefinementResult(cleaned: "Hello.", clearer: "Hello there."))
        #expect(RefinementResult.parse(Data("failed".utf8), provider: .codex) == nil)
        #expect(RefinementResult.decode(Data(#"{"cleaned":"","clearer":"OK"}"#.utf8)) == nil)
        let claude = try JSONSerialization.data(withJSONObject: ["structured_output": ["cleaned": "Hello.", "clearer": "Hello there."]])
        #expect(RefinementResult.parse(claude, provider: .claude)?.cleaned == "Hello.")
    }
}

@MainActor
struct RefinementRunnerTests {
    private func command(delay: Double) -> RefinementRunner.Command {
        let script = #"import sys,time,json; sys.stdin.read(); time.sleep(DELAY); print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':json.dumps({'cleaned':'Hello.','clearer':'Hello there.'})}}))"#.replacingOccurrences(of: "DELAY", with: String(delay))
        return (URL(fileURLWithPath: "/usr/bin/python3"), ["-c", script])
    }
    @Test func cancelsStaleCallbacksAndDeliversOnlyLatest() async throws {
        let runner = RefinementRunner(command: command(delay: 0.1))
        var calls = 0
        runner.run("first", provider: .codex) { _ in calls += 100 }
        runner.run("second", provider: .codex) { result in if result != nil { calls += 1 } }
        try await Task.sleep(for: .seconds(1))
        #expect(calls == 1)
        runner.cancel()
    }
    @Test func timeoutCompletesOnceAndDropsLateSuccess() async throws {
        let runner = RefinementRunner(command: command(delay: 0.5), deadline: .milliseconds(50))
        var calls = 0
        runner.run("sample", provider: .codex) { result in calls += 1; #expect(result == nil) }
        try await Task.sleep(for: .seconds(1))
        #expect(calls == 1)
    }
    @Test func parsesQuotedAndUnquotedMCPServerNames() {
        #expect(RefinementRunner.serverOverrides("[mcp_servers.foo]\nurl='x'\n[mcp_servers.foo.env] # string values\n[mcp_servers.\"bar-baz\"]\n") == ["-c", "mcp_servers.foo.enabled=false", "-c", "mcp_servers.\"bar-baz\".enabled=false"])
    }
}
