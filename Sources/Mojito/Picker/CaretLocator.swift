import AppKit
import ApplicationServices
import os.log

@MainActor
enum CaretLocator {
    private static let log = OSLog(subsystem: "ee.wells.Mojito", category: "CaretLocator")
    /// Set by `caretRect()` so the debug-report snapshot can record which
    /// branch resolved this call. Values include `axBounds`, `elementTopLeft`,
    /// `windowFallback`, and `unavailable`.
    private(set) static var lastOutcome: String = "unavailable"

    /// Screen-space (bottom-left origin) caret rect, or nil.
    ///
    /// Apps sometimes return junk bounds. We require the caret to sit
    /// inside the focused element's frame; otherwise return nil and let
    /// the caller fall back.
    static func caretRect() -> CGRect? {
        // Cached element avoids a synchronous cross-process IPC; the AX
        // observer keeps it fresh. Fall back to system-wide if empty.
        let focused: AXUIElement
        if let cached = FocusedElementCache.shared.element {
            focused = cached
        } else {
            let system = AXUIElementCreateSystemWide()
            guard let focusedRef = copyAttribute(system, key: kAXFocusedUIElementAttribute),
                  CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
            focused = focusedRef as! AXUIElement
        }
        let elementFrame = elementFrame(of: focused)

        if let rect = caretBounds(of: focused), isPlausibleCaret(rect, withinElementFrame: elementFrame) {
            os_log("caret via AX bounds: %{public}@", log: log, type: .info, "\(rect)")
            lastOutcome = "axBounds"
            return rect
        }

        // Fallback to the top-left of the focused element. In AppKit
        // screen coords (bottom-left origin) the TOP is `frame.maxY`, NOT
        // `frame.minY`.
        if let frame = elementFrame,
           isTextInputRole(FocusedElementCache.shared.focusedRole),
           isOnScreen(frame), frame.width < 4000, frame.height < 4000 {
            let tall = frame.height > 160
            let caretHeight: CGFloat = max(16, min(frame.height, 22))
            let x = tall ? frame.midX : frame.minX + 4
            let y = tall
                ? frame.minY + max(36, min(120, frame.height * 0.18))
                : frame.maxY - caretHeight - 2
            let rect = CGRect(x: x, y: y, width: 1, height: caretHeight)
            os_log("caret via element fallback: %{public}@ (frame %{public}@)", log: log, type: .info, "\(rect)", "\(frame)")
            lastOutcome = tall ? "elementLowerFallback" : "elementTopLeft"
            return rect
        }

        // AXWindow (and tiny utility windows) are not text fields. When a
        // native caret is unavailable, anchor near the lower portion of the
        // active app's main window so the picker follows the typing area rather
        // than appearing at the window's top-left corner or at the pointer.
        if let window = FocusedElementCache.shared.activeWindowFrame,
           let rect = windowFallbackRect(windowFrame: window, screenFrames: NSScreen.screens.map(\.frame)) {
            os_log("caret via active-window fallback: %{public}@", log: log, type: .info, "\(rect)")
            lastOutcome = "windowFallback"
            return rect
        }

        os_log("caret unavailable — no AX bounds and no usable element frame", log: log, type: .info)
        lastOutcome = "unavailable"
        return nil
    }

    // MARK: - AX strategies

    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeRef = copyAttribute(element, key: kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID(),
              AXValueGetValue((rangeRef as! AXValue), .cfRange, &range), range.location >= 0 else { return nil }

        let rect = resolveCaret(
            selection: range,
            bounds: { boundsForRange($0, in: element) },
            character: { stringForRange(CFRange(location: $0, length: 1), in: element) }
        )
        return rect.map(convertFromAXScreen)
    }

    /// Picks the caret rect (AX coordinates) from an app's range-bounds
    /// answers. The next glyph `(loc, 1)` is the reliable probe, but it fails
    /// at the end of the text — exactly where people type — and NSTextView
    /// answers the zero-length fallback `(loc, 0)` one line too high. So the
    /// preceding glyph's trailing edge comes first, unless it's a line break
    /// (whose rect sits on the line above the caret).
    static func resolveCaret(
        selection: CFRange,
        bounds: (CFRange) -> CGRect?,
        character: (Int) -> String?
    ) -> CGRect? {
        if let next = bounds(CFRange(location: selection.location, length: max(selection.length, 1))) {
            return next
        }
        if selection.location > 0,
           let previous = character(selection.location - 1),
           previous.rangeOfCharacter(from: .newlines) == nil,
           let glyph = bounds(CFRange(location: selection.location - 1, length: 1)) {
            return CGRect(x: glyph.maxX, y: glyph.minY, width: 0, height: glyph.height)
        }
        return bounds(CFRange(location: selection.location, length: 0))
    }

    private static func boundsForRange(_ range: CFRange, in element: AXUIElement) -> CGRect? {
        var queryRange = range
        guard let queryValue = AXValueCreate(.cfRange, &queryRange) else { return nil }
        var boundsRef: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            queryValue,
            &boundsRef
        )
        guard status == .success, let boundsRef else { return nil }
        var rect = CGRect.zero
        guard CFGetTypeID(boundsRef) == AXValueGetTypeID(),
              AXValueGetValue((boundsRef as! AXValue), .cgRect, &rect) else { return nil }
        guard rect.width >= 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func stringForRange(_ range: CFRange, in element: AXUIElement) -> String? {
        var queryRange = range
        guard let queryValue = AXValueCreate(.cfRange, &queryRange) else { return nil }
        var stringRef: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            queryValue,
            &stringRef
        )
        guard status == .success else { return nil }
        return stringRef as? String
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        guard let posRef = copyAttribute(element, key: kAXPositionAttribute as String) else { return nil }
        guard let sizeRef = copyAttribute(element, key: kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              AXValueGetValue((posRef as! AXValue), .cgPoint, &origin),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size) else { return nil }
        guard size.width > 0, size.height > 0 else { return nil }
        return convertFromAXScreen(CGRect(origin: origin, size: size))
    }

    // MARK: - Validation

    private static func isPlausibleCaret(_ rect: CGRect, withinElementFrame elementFrame: CGRect?) -> Bool {
        guard isOnScreen(rect) else {
            os_log("rejecting caret rect %{public}@ — not on any screen", log: log, type: .info, "\(rect)")
            return false
        }
        if let elementFrame {
            // Caret should sit inside the element (slack for text overflow).
            let slack: CGFloat = 8
            let expanded = elementFrame.insetBy(dx: -slack, dy: -slack)
            if !expanded.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                os_log(
                    "rejecting caret rect %{public}@ — outside focused element %{public}@",
                    log: log, type: .info, "\(rect)", "\(elementFrame)"
                )
                return false
            }
        }
        return true
    }

    private static func isOnScreen(_ rect: CGRect) -> Bool {
        isOnScreen(rect, screens: NSScreen.screens.map(\.frame))
    }

    static func isOnScreen(_ rect: CGRect, screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(rect) }
    }

    /// Returns a stable lower-window anchor in AppKit coordinates. Keeping the
    /// point away from the very bottom leaves room for the picker to clamp on
    /// short windows while still matching the common bottom input area.
    static func windowFallbackRect(windowFrame: CGRect, screenFrames: [CGRect]) -> CGRect? {
        guard windowFrame.width >= 240, windowFrame.height >= 120,
              isOnScreen(windowFrame, screens: screenFrames) else { return nil }
        let y = windowFrame.minY + max(36, min(120, windowFrame.height * 0.18))
        let rect = CGRect(x: windowFrame.midX - 0.5, y: min(y, windowFrame.maxY - 24), width: 1, height: 22)
        return isOnScreen(rect, screens: screenFrames) ? rect : nil
    }

    static func isTextInputRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"].contains(role)
    }

    // MARK: - Coordinate conversion

    /// AX is top-left origin, AppKit is bottom-left, both rooted at the
    /// menu-bar screen. Flip Y.
    private static func convertFromAXScreen(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.height
        let flippedY = primaryHeight - rect.origin.y - rect.height
        return CGRect(x: rect.origin.x, y: flippedY, width: rect.width, height: rect.height)
    }

    private static func copyAttribute(_ element: AXUIElement, key: String) -> AnyObject? {
        var ref: AnyObject?
        return AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success ? ref : nil
    }
}
