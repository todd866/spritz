import AppKit

/// Recognize only a single insertion/replacement at the pre-dictation caret.
/// Existing surrounding text never leaves this process.
enum DictatedInsertion {
    static func extract(before: String, selection: NSRange, after: String, caret: NSRange) -> String? {
        let original = before as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location <= original.length, selection.length <= original.length - selection.location,
              caret.length == 0 else { return nil }
        let prefix = original.substring(to: selection.location)
        let suffix = original.substring(from: selection.location + selection.length)
        let value = after as NSString
        let start = (prefix as NSString).length, tail = (suffix as NSString).length
        guard value.length > start + tail, after.hasPrefix(prefix), after.hasSuffix(suffix),
              caret.location == value.length - tail else { return nil }
        let text = value.substring(with: NSRange(location: start, length: value.length - start - tail))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 24_000 else { return nil }
        return text
    }
}

/// Observes the destination field, not ChatGPT's UI or its audio internals.
/// Bounded to one user-initiated hold; user typing or a focus change cancels it.
@MainActor
final class NativeDictationCapture {
    static let shared = NativeDictationCapture()
    private var generation = UUID()
    private var poll: Task<Void, Never>?
    private var released = false
    private var active = false
    private var appleTranscript: String?
    func receiveApple(_ text: String) { if active { appleTranscript = text } }
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }
    private var baseline: (AXUIElement, pid_t, String, NSRange)?
    func cancel() { active = false; generation = UUID(); poll?.cancel(); poll = nil; baseline = nil; released = false; appleTranscript = nil }
    func start() {
        cancel()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        active = true
        let id = generation
        SpeechFocusValidator.capture(pid: pid) { [weak self] element in
            MainActor.assumeIsolated {
                guard let self, self.generation == id, let element else { return }
                DictationFieldReader.read(element: element, pid: pid) { [weak self] value, selection in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == id, let value, let selection else { return }
                        self.baseline = (element, pid, value, selection)
                        if self.released { self.waitForInsertion() }
                    }
                }
            }
        }
    }
    func finish() { released = true; if baseline != nil { waitForInsertion() } }
    private func waitForInsertion() {
        guard poll == nil, let (element, pid, before, selection) = baseline else { return }
        let id = generation
        poll = Task { @MainActor in
            defer { if self.generation == id { self.poll = nil; self.baseline = nil; self.appleTranscript = nil } }
            var previous: String?, stable = 0
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.generation == id,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let (value, caret): (String?, NSRange?) = await withCheckedContinuation { continuation in
                    DictationFieldReader.read(element: element, pid: pid) { continuation.resume(returning: ($0, $1)) }
                }
                guard !Task.isCancelled, self.generation == id else { return }
                guard let value, let caret else { self.cancel(); return }
                guard value != before else { continue }
                guard let text = DictatedInsertion.extract(before: before, selection: selection, after: value, caret: caret) else { self.cancel(); return }
                stable = text == previous ? stable + 1 : 0; previous = text
                if stable >= 2 {
                    let apple = self.appleTranscript
                    self.cancel()
                    LocalTelemetry.shared.record(.nativeTranscriptCaptured)
                    DictationAlternatives.shared.begin(text: text, element: element, pid: pid, native: true, apple: apple)
                    return
                }
            }
            self.cancel()
        }
    }
}
