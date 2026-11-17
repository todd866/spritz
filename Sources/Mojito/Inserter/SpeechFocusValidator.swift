import ApplicationServices
import Foundation

enum SpeechFocusValidator {
    enum Outcome: Equatable { case match, lookupFailed, changed }
    private static let queue = DispatchQueue(label: "Spritz.speechFocus", qos: .userInitiated)

    /// Snapshot the authoritative field at gesture start; the shared cache can
    /// contain an AX notification sender/container instead of the focused leaf.
    static func capture(pid: pid_t, read: (() -> AXUIElement?)? = nil,
                        classify: ((AXUIElement) -> (secure: Bool, editable: Bool, role: String?))? = nil,
                        completion: @escaping (AXUIElement?) -> Void) {
        queue.async {
            var element = read.map { $0() } ?? focusedElement(pid: pid)
            if let candidate = element {
                AXUIElementSetMessagingTimeout(candidate, 0.1)
                let info = classify?(candidate) ?? AppContextDetector.classify(candidate)
                if info.secure || !info.editable || !TouchBarRequestPolicy.isTextRole(info.role) { element = nil }
            }
            let captured = element
            DispatchQueue.main.async { completion(captured) }
        }
    }
    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           role as? String == "AXWindow" {
            var nested: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &nested) == .success,
               let nested, CFGetTypeID(nested) == AXUIElementGetTypeID() {
                element = unsafeBitCast(nested, to: AXUIElement.self)
            }
        }
        return element
    }

    /// Never blocks the event-tap thread. Only reads element identity, not text.
    static func validate(expected: AXUIElement, pid: pid_t,
                         read: (() -> AXUIElement?)? = nil,
                         completion: @escaping (Outcome) -> Void) {
        queue.async {
            let actual: AXUIElement?
            if let read { actual = read() }
            else { actual = focusedElement(pid: pid) }
            let outcome: Outcome = actual.map { CFEqual($0, expected) ? .match : .changed } ?? .lookupFailed
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
