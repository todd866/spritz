import ApplicationServices
import Foundation

enum SpeechFocusValidator {
    enum Outcome: Equatable { case match, lookupFailed, changed }
    private static let queue = DispatchQueue(label: "Spritz.speechFocus", qos: .userInitiated)

    /// Never blocks the event-tap thread. Only reads element identity, not text.
    static func validate(expected: AXUIElement, pid: pid_t,
                         read: (() -> AXUIElement?)? = nil,
                         completion: @escaping (Outcome) -> Void) {
        queue.async {
            let actual: AXUIElement?
            if let read { actual = read() }
            else {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.1)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    actual = unsafeBitCast(value, to: AXUIElement.self)
                } else { actual = nil }
            }
            let outcome: Outcome = actual.map { CFEqual($0, expected) ? .match : .changed } ?? .lookupFailed
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
