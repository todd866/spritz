import Combine
import Foundation

/// The bare-`:` Quick Access row: a fixed set of 8 slots, each either **auto**
/// (filled from most-used) or **pinned** to a specific emoji. Persisted as an
/// 8-element `[String]` where `""` marks an auto slot.
@MainActor
final class QuickAccessStore: ObservableObject {
    static let shared = QuickAccessStore()
    static let slotCount = 8

    /// One entry per slot: `nil` = auto, else a pinned hexcode.
    @Published private(set) var slots: [String?]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = (defaults.array(forKey: PrefsKey.quickAccessSlots) as? [String]) ?? []
        var parsed: [String?] = raw.map { $0.isEmpty ? nil : $0 }
        if parsed.count < Self.slotCount {
            parsed += Array(repeating: nil, count: Self.slotCount - parsed.count)
        }
        self.slots = Array(parsed.prefix(Self.slotCount))
    }

    /// Pin `hexcode` to `index`, clearing it from any other slot so a glyph
    /// never occupies two slots.
    func pin(_ hexcode: String, at index: Int) {
        guard slots.indices.contains(index) else { return }
        for i in slots.indices where slots[i] == hexcode { slots[i] = nil }
        slots[index] = hexcode
        persist()
    }

    /// Reset a single slot back to auto (most-used).
    func reset(at index: Int) {
        guard slots.indices.contains(index), slots[index] != nil else { return }
        slots[index] = nil
        persist()
    }

    func resetAll() {
        guard hasPins else { return }
        slots = Array(repeating: nil, count: Self.slotCount)
        persist()
    }

    var hasPins: Bool { slots.contains { $0 != nil } }

    private func persist() {
        defaults.set(slots.map { $0 ?? "" }, forKey: PrefsKey.quickAccessSlots)
    }
}

/// One resolved Quick Access slot for display: the emoji that fills it (if
/// any) and whether the user pinned it.
struct ResolvedSlot {
    let emoji: Emoji?
    let pinned: Bool
}

/// Resolves the Quick Access slots to concrete emoji: pinned slots show their
/// emoji; auto slots fill, in slot order, from most-used (skipping symbols,
/// pinned glyphs, and anything already shown).
@MainActor
enum QuickAccess {
    static func resolvedPerSlot(
        store: QuickAccessStore,
        database: EmojiDatabase,
        usage: [String: Int]
    ) -> [ResolvedSlot] {
        let pinned = Set(store.slots.compactMap { $0 })
        var pool = usage
            .filter { $0.value > 0 && !$0.key.hasPrefix("SYM_") && !pinned.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
            .makeIterator()
        var used = pinned
        var out: [ResolvedSlot] = []
        for slot in store.slots {
            if let hex = slot {
                // A pinned symbol stores a `SYM_…` hexcode, which lives in
                // SymbolsDatabase, not the emoji DB.
                let emoji = database.byHexcode[hex]
                    ?? (hex.hasPrefix("SYM_") ? SymbolsDatabase.byHexcode[hex] : nil)
                out.append(ResolvedSlot(emoji: emoji, pinned: true))
            } else {
                var fill: Emoji?
                while let hex = pool.next() {
                    guard !used.contains(hex), let emoji = database.byHexcode[hex] else { continue }
                    used.insert(hex)
                    fill = emoji
                    break
                }
                out.append(ResolvedSlot(emoji: fill, pinned: false))
            }
        }
        return out
    }

    /// Flat list of the resolved emoji (drops empty auto slots) — the bare-`:`
    /// pill corpus and the browser's Quick Access section.
    static func resolved(
        store: QuickAccessStore,
        database: EmojiDatabase,
        usage: [String: Int]
    ) -> [Emoji] {
        resolvedPerSlot(store: store, database: database, usage: usage).compactMap(\.emoji)
    }
}

/// Keeps every used emoji once, newest first. Counts and recent order are
/// independent: a single new pick should immediately lead Recent.
enum EmojiRecents {
    static func record(_ hexcode: String, defaults: UserDefaults = .standard) {
        guard !hexcode.hasPrefix("SYM_") else { return }
        var recent = defaults.stringArray(forKey: PrefsKey.recentEmoji) ?? []
        recent.removeAll { $0 == hexcode }
        recent.insert(hexcode, at: 0)
        defaults.set(recent, forKey: PrefsKey.recentEmoji)
    }
}

/// Assigns the single-key labels used by the compact emoji picker.
///
/// Bindings are deliberately independent of usage ranking: an existing
/// binding is kept forever, while new emoji get a deterministic mnemonic (or
/// a balanced fallback) in the order supplied by the caller.
enum EmojiLetterBindings {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")

    /// Resolve one-letter bindings for `candidates`, carrying forward valid
    /// entries in `saved`. The returned keys are canonicalised uppercase
    /// hexcodes and values are lowercase ASCII letters.
    static func resolve(candidates: [Emoji], saved: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        // Sorting makes duplicate differently-cased saved keys deterministic.
        for key in saved.keys.sorted() {
            guard let canonical = canonicalHex(key),
                  let letter = asciiLetter(saved[key] ?? "") else { continue }
            if result[canonical] == nil { result[canonical] = String(letter) }
        }

        var unique: [Emoji] = []
        var seen = Set<String>()
        for emoji in candidates {
            guard let hex = canonicalHex(emoji.hexcode), seen.insert(hex).inserted else { continue }
            unique.append(emoji)
        }

        var counts = Dictionary(uniqueKeysWithValues: alphabet.map { ($0, 0) })
        for letter in result.values { counts[letter.first!, default: 0] += 1 }
        for emoji in unique {
            let hex = canonicalHex(emoji.hexcode)!
            if result[hex] != nil { continue }

            let choices = mnemonicChoices(for: emoji)
            let minimum = choices.map { counts[$0, default: 0] }.min() ?? 0
            let chosen = choices.first(where: { counts[$0, default: 0] == minimum })!
            result[hex] = String(chosen)
            counts[chosen, default: 0] += 1
        }
        return result
    }

    static func canonicalHex(_ value: String) -> String? {
        if value.hasPrefix("SYM_") { return value }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isHexDigit } }) else { return nil }
        return pieces.map { $0.uppercased() }.joined(separator: "-")
    }

    private static func asciiLetter(_ value: String) -> Character? {
        guard value.unicodeScalars.count == 1,
              let scalar = value.unicodeScalars.first else { return nil }
        if scalar.value >= 97 && scalar.value <= 122 { return Character(scalar) }
        if scalar.value >= 65 && scalar.value <= 90 {
            return Character(UnicodeScalar(scalar.value + 32)!)
        }
        return nil
    }

    private static func mnemonicChoices(for emoji: Emoji) -> [Character] {
        let curated: [String: Character] = [
            "2764": "h", "2764-FE0F": "h",
            "1F3F4-200D-2620": "p", "1F3F4-200D-2620-FE0F": "p", "1F44D": "t",
            "1F480": "s", "1F1E6-1F1FA": "a", "1F916": "r", "1F62D": "c",
            "1F914": "t", "1F525": "f"
        ]
        var out: [Character] = []
        if let letter = curated[canonicalHex(emoji.hexcode) ?? ""] { out.append(letter) }
        let labelWords = words(emoji.label)
        let shortcodeWords = emoji.shortcodes.flatMap(words)
        for word in labelWords + shortcodeWords { if let first = word.first { out.append(first) } }
        for word in labelWords + shortcodeWords { out.append(contentsOf: word) }
        out.append(contentsOf: alphabet)
        return out.reduce(into: []) { partial, letter in
            if !partial.contains(letter) { partial.append(letter) }
        }
    }

    private static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if scalar.value >= 97 && scalar.value <= 122 {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
