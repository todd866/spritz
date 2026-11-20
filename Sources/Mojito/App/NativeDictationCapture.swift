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
    private var baselineFailed = false
    private var appleTranscript: String?
    private var fallbackTarget: (AXUIElement?, pid_t)?
    func receiveApple(_ text: String) {
        guard active else { return }
        appleTranscript = text
        if baselineFailed && released {
            deliverAppleFallback()
        }
    }
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }
    private var baseline: (AXUIElement, pid_t, String, NSRange)?
    func cancel() {
        active = false; generation = UUID(); poll?.cancel(); poll = nil
        baseline = nil; baselineFailed = false; released = false
        appleTranscript = nil; fallbackTarget = nil
    }
    func start() {
        cancel()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        active = true
        fallbackTarget = (nil, pid)
        let id = generation
        SpeechFocusValidator.capture(pid: pid) { [weak self] element in
            MainActor.assumeIsolated {
                guard let self, self.generation == id else { return }
                guard let element else {
                    self.handleBaselineFailure(element: nil, pid: pid)
                    return
                }
                self.fallbackTarget = (element, pid)
                DictationFieldReader.read(element: element, pid: pid) { [weak self] value, selection in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == id else { return }
                        guard let value, let selection else {
                            self.handleBaselineFailure(element: element, pid: pid)
                            return
                        }
                        self.baseline = (element, pid, value, selection)
                        if self.released { self.waitForInsertion() }
                    }
                }
            }
        }
    }
    func finish() {
        released = true
        if baseline != nil {
            waitForInsertion()
        } else if baselineFailed, appleTranscript != nil {
            deliverAppleFallback()
        }
    }
    private func handleBaselineFailure(element: AXUIElement?, pid: pid_t) {
        baselineFailed = true
        fallbackTarget = (element, pid)
        LocalTelemetry.shared.record(.nativeBaselineFailed)
        if released, appleTranscript != nil {
            deliverAppleFallback()
        }
    }
    private func deliverAppleFallback() {
        guard let apple = appleTranscript, !apple.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancel(); return
        }
        let target = fallbackTarget
        cancel()
        LocalTelemetry.shared.record(.nativeFallbackToApple)
        DictationAlternatives.shared.begin(text: apple, element: target?.0, pid: target?.1, native: false)
    }
    private func waitForInsertion() {
        guard poll == nil, let (element, pid, before, selection) = baseline else { return }
        let id = generation
        poll = Task { @MainActor in
            defer { if self.generation == id { self.poll = nil; self.baseline = nil; self.appleTranscript = nil } }
            var previous: String?, stable = 0
            // When an Apple transcript is already captured, fall back to it after
            // 5 s if no native insertion lands rather than waiting a full 30 s.
            var ticksAfterApple = 0
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.generation == id,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let (value, caret): (String?, NSRange?) = await withCheckedContinuation { continuation in
                    DictationFieldReader.read(element: element, pid: pid) { continuation.resume(returning: ($0, $1)) }
                }
                guard !Task.isCancelled, self.generation == id else { return }
                guard let value, let caret else {
                    LocalTelemetry.shared.record(.nativeDiffMismatch)
                    self.deliverAppleFallback()
                    return
                }
                if value == before {
                    if self.appleTranscript != nil {
                        ticksAfterApple += 1
                        if ticksAfterApple >= 20 {
                            LocalTelemetry.shared.record(.nativeCaptureTimeout)
                            self.deliverAppleFallback()
                            return
                        }
                    }
                    continue
                }
                guard let text = DictatedInsertion.extract(before: before, selection: selection, after: value, caret: caret) else {
                    LocalTelemetry.shared.record(.nativeDiffMismatch)
                    self.deliverAppleFallback()
                    return
                }
                stable = text == previous ? stable + 1 : 0; previous = text
                if stable >= 2 {
                    let apple = self.appleTranscript
                    self.cancel()
                    LocalTelemetry.shared.record(.nativeTranscriptCaptured)
                    DictationAlternatives.shared.begin(text: text, element: element, pid: pid, native: true, apple: apple)
                    return
                }
            }
            LocalTelemetry.shared.record(.nativeCaptureTimeout)
            self.deliverAppleFallback()
        }
    }
}
