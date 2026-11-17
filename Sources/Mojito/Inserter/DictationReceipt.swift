import AppKit

struct DictationReceipt: Equatable {
    let value: String
    let caret: Int
    let text: String
    static func capture(value: String, selection: NSRange, text: String) -> Self? {
        let length = (value as NSString).length, size = (text as NSString).length
        guard !text.isEmpty, selection.length == 0, selection.location >= size,
              selection.location <= length,
              (value as NSString).substring(with: NSRange(location: selection.location - size, length: size)) == text else { return nil }
        return Self(value: value, caret: selection.location, text: text)
    }
    func matches(value: String, selection: NSRange) -> Bool {
        self.value == value && selection == NSRange(location: caret, length: 0)
    }
}

enum DictationFieldReader {
    private static let queue = DispatchQueue(label: "Spritz.dictationReceipt", qos: .userInitiated)
    static func read(element: AXUIElement, pid: pid_t, completion: @escaping (String?, NSRange?) -> Void) {
        queue.async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            AXUIElementSetMessagingTimeout(element, 0.1)
            var focus: CFTypeRef?, value: CFTypeRef?, range: CFTypeRef?
            var selection = CFRange()
            let valid = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focus) == .success
                && focus.map { CFEqual($0, element) } == true
                && AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success
                && AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
            var result: NSRange?
            if valid, let range, CFGetTypeID(range) == AXValueGetTypeID(),
               AXValueGetValue(unsafeBitCast(range, to: AXValue.self), .cfRange, &selection), selection.location >= 0, selection.length >= 0 {
                result = NSRange(location: selection.location, length: selection.length)
            }
            let text = valid ? value as? String : nil
            DispatchQueue.main.async { completion(text, result) }
        }
    }
}
