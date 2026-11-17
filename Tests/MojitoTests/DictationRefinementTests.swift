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

@MainActor
struct DictationCycleTests {
    @Test func cyclesBothWaysAndWaitsForAlternatives() {
        #expect(DictationAlternatives.nextIndex(current: 0, count: 1, backward: false) == nil)
        #expect(DictationAlternatives.nextIndex(current: 0, count: 3, backward: false) == 1)
        #expect(DictationAlternatives.nextIndex(current: 1, count: 3, backward: false) == 2)
        #expect(DictationAlternatives.nextIndex(current: 2, count: 3, backward: false) == 0)
        #expect(DictationAlternatives.nextIndex(current: 0, count: 3, backward: true) == 2)
    }
    @Test func fnTabDoesNotStealOrdinaryTabOrOtherChords() {
        #expect(KeyMonitor.isSpeechCycle(keyCode: 48, flags: .maskSecondaryFn))
        #expect(KeyMonitor.isSpeechCycle(keyCode: 48, flags: [.maskSecondaryFn, .maskShift]))
        #expect(!KeyMonitor.isSpeechCycle(keyCode: 48, flags: []))
        #expect(!KeyMonitor.isSpeechCycle(keyCode: 48, flags: [.maskSecondaryFn, .maskCommand]))
        var gesture = FnGesture()
        gesture.press(at: 0, modified: false)
        #expect(gesture.interrupt() == .cancel)
        #expect(gesture.release(at: 0.1) == nil)
    }
}

struct DictatedInsertionTests {
    @Test func extractsOnlyInsertedPassageAndPreservesSurroundingText() {
        #expect(DictatedInsertion.extract(before: "Before. After.", selection: NSRange(location: 8, length: 0), after: "Before. New words. After.", caret: NSRange(location: 19, length: 0)) == "New words. ")
        #expect(DictatedInsertion.extract(before: "old", selection: NSRange(location: 0, length: 3), after: "👩🏽‍💻", caret: NSRange(location: 7, length: 0)) == "👩🏽‍💻")
        #expect(DictatedInsertion.extract(before: "before", selection: NSRange(location: 6, length: 0), after: "different text", caret: NSRange(location: 14, length: 0)) == nil)
        #expect(DictatedInsertion.extract(before: "", selection: NSRange(location: 0, length: 0), after: "Hello", caret: NSRange(location: 2, length: 0)) == nil)
        #expect(DictatedInsertion.extract(before: "", selection: NSRange(location: Int.max, length: 1), after: "Hello", caret: NSRange(location: 5, length: 0)) == nil)
    }
}

@MainActor
struct CombinedPickerTests {
    @Test func tabCyclesTextWhileOtherKeysRemainWithEmoji() {
        let model = DictationAlternatives(preview: true)
        model.choices = ["Apple text", "GPT text", "Reviewed text"]
        model.labels = ["Apple", "GPT", "Reviewed"]
        model.copyOnly = false
        model.showEmbedded()
        #expect(model.handle(.tabKey(shift: false)))
        #expect(model.selected == 1)
        #expect(model.embedded)
        #expect(model.textPreviewActive)
        #expect(model.handle(.tabKey(shift: true)))
        #expect(model.selected == 0)
        #expect(model.handle(.tabKey(shift: true)))
        #expect(model.selected == 2)
        #expect(model.handle(.returnKey(shift: false)))
        #expect(model.copyOnly) // No receipt: Enter is handled safely without insertion.
        #expect(!model.handle(.nameChar("a")))
        #expect(!model.handle(.returnKey(shift: false)))
        model.clear()
    }
    @Test func escapeDiscardsPreviewAndClosesBrowser() {
        let model = DictationAlternatives(preview: true)
        model.choices = ["Original", "Reviewed"]
        model.showEmbedded()
        var browser = TriggerStateMachine()
        browser.enterBrowsing(query: "")
        #expect(model.handle(.tabKey(shift: false)))
        #expect(!model.handle(.escape))
        let result = browser.handle(.escape)
        #expect(result.consumesKey)
        #expect(result.action == .closeBrowser)
        model.hide()
        #expect(!model.embedded)
        #expect(model.choices == ["Original", "Reviewed"])
    }
}
