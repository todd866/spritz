import Foundation
import SpritzCoreFFI
import UIKit

enum SpritzIosConstants {
    static let appGroupID = "group.io.github.todd866.SpritzMobile"
    static let keyboardBundleID = "io.github.todd866.SpritzMobile.Keyboard"
}

enum EnglishVariantDTO: String, Codable, CaseIterable, Identifiable {
    case au
    case uk
    case us

    var id: String { rawValue }
    var title: String {
        switch self {
        case .au: return "AU"
        case .uk: return "UK"
        case .us: return "US"
        }
    }
}

enum AutocorrectModeDTO: String, Codable, CaseIterable, Identifiable {
    case off
    case gentle
    case smart

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .gentle: return "Gentle"
        case .smart: return "Smart"
        }
    }
}

enum ShiftStateDTO: String, Codable {
    case off
    case once
    case capsLock

    var code: Int32 {
        switch self {
        case .off: return 0
        case .once: return 1
        case .capsLock: return 2
        }
    }
}

struct KeyboardConfigDTO: Codable, Equatable {
    var numberRow: Bool
    var keyFlicks: Bool
    var glideTyping: Bool
    var autocorrect: AutocorrectModeDTO
    var englishVariant: EnglishVariantDTO
    var haptics: Bool
    var autoCaps: Bool
    var doubleSpacePeriod: Bool
    var skinTone: String
    var snippets: [String: String]
    var personalWords: [String]
    var rejectedCorrections: [String: String]
}

struct CandidateDTO: Codable, Equatable {
    let text: String
    let kind: String
    let autoCommit: Bool
}

struct EmojiHintDTO: Codable, Equatable {
    let hex: String
    let glyph: String
    let label: String
}

struct TextEditDTO: Codable, Equatable {
    let deleteBackward: Int
    let insert: String
}

struct KeyboardOutputDTO: Codable, Equatable {
    let edit: TextEditDTO
    let candidates: [CandidateDTO]
    let emojiHints: [EmojiHintDTO]
    let undoWord: String?
    let shiftState: ShiftStateDTO
    let autoSpaceActive: Bool
}

struct EmojiItemDTO: Codable, Equatable {
    let hex: String
    let glyph: String
    let label: String
    let category: String
}

struct EmojiSectionDTO: Codable, Equatable {
    let category: String
    let title: String
    let symbol: String
    let startIndex: Int
    let count: Int
}

struct EmojiSnapshotDTO: Codable, Equatable {
    let mode: String
    let availableModes: [String]
    let pinned: [EmojiItemDTO]
    let items: [EmojiItemDTO]
    let sections: [EmojiSectionDTO]
}

struct EmojiPickDTO: Codable, Equatable {
    let hex: String
    let glyph: String
}

@MainActor
protocol TextDocumentTarget: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    var selectedText: String? { get }
    var returnKeyType: UIReturnKeyType { get }
    var keyboardAppearance: UIKeyboardAppearance { get }
    var supportsSelectionExtension: Bool { get }
    func insertText(_ text: String)
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
    func extendSelection(byCharacterOffset offset: Int)
    func undoEdit()
    func redoEdit()
}

@MainActor
final class TextDocumentProxyTarget: TextDocumentTarget {
    private weak var controller: UIInputViewController?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    var documentContextBeforeInput: String? { proxy?.documentContextBeforeInput }
    var documentContextAfterInput: String? { proxy?.documentContextAfterInput }
    var selectedText: String? { proxy?.selectedText }
    var returnKeyType: UIReturnKeyType { proxy?.returnKeyType ?? .default }
    var keyboardAppearance: UIKeyboardAppearance { proxy?.keyboardAppearance ?? .default }
    var supportsSelectionExtension: Bool { false }

    func insertText(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
    }
    func extendSelection(byCharacterOffset offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
    }
    func undoEdit() {}
    func redoEdit() {}
}

@MainActor
final class TextViewDocumentTarget: TextDocumentTarget {
    weak var textView: UITextView?
    var onDidMutate: (() -> Void)?

    init(textView: UITextView? = nil) {
        self.textView = textView
    }

    var documentContextBeforeInput: String? {
        guard let tv = textView else { return nil }
        let text = tv.text ?? ""
        let ns = text as NSString
        let loc = min(max(0, tv.selectedRange.location), ns.length)
        return ns.substring(to: loc)
    }

    var documentContextAfterInput: String? {
        guard let tv = textView else { return nil }
        let text = tv.text ?? ""
        let ns = text as NSString
        let end = min(max(0, NSMaxRange(tv.selectedRange)), ns.length)
        return ns.substring(from: end)
    }

    var selectedText: String? {
        guard let tv = textView, tv.selectedRange.length > 0 else { return nil }
        let ns = (tv.text ?? "") as NSString
        let range = NSIntersectionRange(tv.selectedRange, NSRange(location: 0, length: ns.length))
        return range.length > 0 ? ns.substring(with: range) : nil
    }

    var returnKeyType: UIReturnKeyType { textView?.returnKeyType ?? .default }
    var keyboardAppearance: UIKeyboardAppearance { textView?.keyboardAppearance ?? .default }
    var supportsSelectionExtension: Bool { true }

    func insertText(_ text: String) {
        guard let tv = textView else { return }
        tv.insertText(text)
        onDidMutate?()
    }

    func deleteBackward() {
        guard let tv = textView else { return }
        tv.deleteBackward()
        onDidMutate?()
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        guard let tv = textView else { return }
        let len = (tv.text ?? "").utf16.count
        let cur = tv.selectedRange.location + tv.selectedRange.length
        let target = min(max(0, cur + offset), len)
        tv.selectedRange = NSRange(location: target, length: 0)
        onDidMutate?()
    }

    func extendSelection(byCharacterOffset offset: Int) {
        guard let tv = textView else { return }
        let len = (tv.text ?? "").utf16.count
        var loc = tv.selectedRange.location
        var length = tv.selectedRange.length
        if offset < 0 {
            let delta = min(loc, -offset)
            loc -= delta
            length += delta
        } else {
            let delta = min(len - (loc + length), offset)
            length += max(0, delta)
        }
        tv.selectedRange = NSRange(location: loc, length: length)
        onDidMutate?()
    }

    func undoEdit() {
        textView?.undoManager?.undo()
        onDidMutate?()
    }

    func redoEdit() {
        textView?.undoManager?.redo()
        onDidMutate?()
    }
}

@MainActor
final class SpritzIosBridge {
    private var engine: OpaquePointer?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    static func storageDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: SpritzIosConstants.appGroupID)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Spritz", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func isKeyboardEnabledInSettings() -> Bool {
        let keyboards = UserDefaults.standard.stringArray(forKey: "AppleKeyboards") ?? []
        return keyboards.contains(SpritzIosConstants.keyboardBundleID)
    }

    init() {
        let dir = Self.storageDirectory().path
        engine = dir.withCString { cConfig in
            dir.withCString { cState in
                spritz_ios_create(cConfig, cState)
            }
        }
    }

    deinit {
        if let engine {
            spritz_ios_destroy(engine)
        }
    }

    private func decodeJSON<T: Decodable>(_ ptr: UnsafeMutablePointer<CChar>?, as type: T.Type) -> T? {
        guard let ptr else { return nil }
        defer { spritz_ios_free_cstr(ptr) }
        let str = String(cString: ptr)
        return try? decoder.decode(T.self, from: Data(str.utf8))
    }

    func applyEdit(_ edit: TextEditDTO, to target: TextDocumentTarget) {
        if edit.deleteBackward > 0 {
            for _ in 0..<edit.deleteBackward {
                target.deleteBackward()
            }
        }
        if !edit.insert.isEmpty {
            target.insertText(edit.insert)
        }
    }

    func tapKey(_ ch: String, normPoint: CGPoint, target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ch.withCString { cKey in
            ctx.withCString { cCtx in
                decodeJSON(spritz_ios_tap_key(engine, cKey, Float(normPoint.x), Float(normPoint.y), cCtx), as: KeyboardOutputDTO.self)
            }
        }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func insertDirect(_ text: String, target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = text.withCString { cText in
            ctx.withCString { cCtx in
                decodeJSON(spritz_ios_insert_direct(engine, cText, cCtx), as: KeyboardOutputDTO.self)
            }
        }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func tapSpace(target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ctx.withCString { decodeJSON(spritz_ios_tap_space(engine, $0), as: KeyboardOutputDTO.self) }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func tapReturn(target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ctx.withCString { decodeJSON(spritz_ios_tap_return(engine, $0), as: KeyboardOutputDTO.self) }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func tapBackspace(target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ctx.withCString { decodeJSON(spritz_ios_tap_backspace(engine, $0), as: KeyboardOutputDTO.self) }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func swipeDeleteWord(target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ctx.withCString { decodeJSON(spritz_ios_swipe_delete_word(engine, $0), as: KeyboardOutputDTO.self) }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func undoLastDelete(target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let out = decodeJSON(spritz_ios_undo_last_delete(engine), as: KeyboardOutputDTO.self)
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func finishGlide(points: [CGPoint], target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine, !points.isEmpty else { return nil }
        var flat: [Float] = []
        flat.reserveCapacity(points.count * 2)
        for p in points {
            flat.append(Float(p.x))
            flat.append(Float(p.y))
        }
        let ctx = target.documentContextBeforeInput ?? ""
        let out: KeyboardOutputDTO? = flat.withUnsafeBufferPointer { buf in
            ctx.withCString { cCtx in
                decodeJSON(spritz_ios_finish_glide(engine, buf.baseAddress, points.count, cCtx), as: KeyboardOutputDTO.self)
            }
        }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func acceptCandidate(index: Int, target: TextDocumentTarget) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target.documentContextBeforeInput ?? ""
        let out = ctx.withCString { decodeJSON(spritz_ios_accept_candidate(engine, index, $0), as: KeyboardOutputDTO.self) }
        if let out { applyEdit(out.edit, to: target) }
        return out
    }

    func setShift(_ state: ShiftStateDTO) {
        guard let engine else { return }
        spritz_ios_set_shift(engine, state.code)
    }

    func syncContext(target: TextDocumentTarget?) -> KeyboardOutputDTO? {
        guard let engine else { return nil }
        let ctx = target?.documentContextBeforeInput ?? ""
        return ctx.withCString { decodeJSON(spritz_ios_sync_context(engine, $0), as: KeyboardOutputDTO.self) }
    }

    func emojiSnapshot(mode: String, query: String, contextBefore: String) -> EmojiSnapshotDTO? {
        guard let engine else { return nil }
        return mode.withCString { cMode in
            query.withCString { cQuery in
                contextBefore.withCString { cCtx in
                    decodeJSON(spritz_ios_emoji_snapshot(engine, cMode, cQuery, cCtx), as: EmojiSnapshotDTO.self)
                }
            }
        }
    }

    func emojiPick(hex: String, target: TextDocumentTarget?) -> EmojiPickDTO? {
        guard let engine else { return nil }
        let picked = hex.withCString { decodeJSON(spritz_ios_emoji_pick(engine, $0), as: EmojiPickDTO.self) }
        if let glyph = picked?.glyph, !glyph.isEmpty {
            target?.insertText(glyph)
        }
        return picked
    }

    func emojiPin(slotIndex: Int, hex: String) -> [EmojiItemDTO]? {
        guard let engine else { return nil }
        return hex.withCString { decodeJSON(spritz_ios_emoji_pin(engine, slotIndex, $0), as: [EmojiItemDTO].self) }
    }

    func loadConfig() -> KeyboardConfigDTO {
        if let engine,
           let cfg = decodeJSON(spritz_ios_get_config_json(engine), as: KeyboardConfigDTO.self) {
            return cfg
        }
        return KeyboardConfigDTO(
            numberRow: true,
            keyFlicks: true,
            glideTyping: true,
            autocorrect: .gentle,
            englishVariant: .au,
            haptics: true,
            autoCaps: true,
            doubleSpacePeriod: true,
            skinTone: "default",
            snippets: [:],
            personalWords: [],
            rejectedCorrections: [:]
        )
    }

    @discardableResult
    func saveConfig(_ config: KeyboardConfigDTO) -> Bool {
        guard let engine,
              let data = try? encoder.encode(config),
              let str = String(data: data, encoding: .utf8) else {
            return false
        }
        return str.withCString { spritz_ios_set_config_json(engine, $0) }
    }

    @discardableResult
    func learnWord(_ word: String) -> Bool {
        guard let engine else { return false }
        return word.withCString { spritz_ios_learn_word(engine, $0) }
    }

    @discardableResult
    func forgetWord(_ word: String) -> Bool {
        guard let engine else { return false }
        return word.withCString { spritz_ios_forget_word(engine, $0) }
    }
}
