import Combine
import Foundation

/// Drives the in-panel emoji browser. Input arrives via the trigger state
/// machine (the panel is non-key, like the inline picker), so search + grid
/// navigation are set from the Engine rather than from focusable controls.
///
/// Navigation model: **one continuous scrolling list** (like the macOS system
/// emoji picker). Every category is a section in a single scroll view; the tab
/// bar *jumps* to a section and highlights whichever section you've scrolled to.
/// Cells carry a global flat index so keyboard nav + `scrollTo` address the
/// whole library with one integer, while section headers carry the category as
/// their scroll id.
@MainActor
final class EmojiBrowserViewModel: ObservableObject {
    /// Grid column count — keep in sync with the view's LazyVGrid.
    static let columns = 7
    /// Digit keys 1–9 then 0, one per column.
    static let numberSlotCount = 10
    static let shortcutColumns = numberSlotCount
    static let numberKeys: [Character] = Array("1234567890")
    static let letterKeys: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
    static let releasedLettersKey = "mojito.releasedLetters"
    /// Rows under the search field and mode bar. The grid is topped up to this
    /// so the panel is full even when the letter keys run out.
    static let minimumShortcutSlots = shortcutColumns * 8
    private let supportsShortcuts: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case suggested, mostUsed, recent, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .suggested: return "Suggested"
            case .mostUsed: return "Most used"
            case .recent: return "Recent"
            case .all: return "All"
            }
        }
    }
    /// The tabs shown for this opening. Context suggestions are opt-in: when
    /// AX context has no exact emoji keyword matches we leave the normal
    /// three-tab surface unchanged.
    var availableModes: [Mode] {
        hasContextSuggestions ? [.suggested, .mostUsed, .recent, .all] : [.mostUsed, .recent, .all]
    }
    var onModeChange: (() -> Void)?
    /// Called when the user explicitly enters or leaves the text-search mode.
    /// Shortcut mode is the default: one digit or letter picks immediately.
    var onSearchModeChange: ((Bool) -> Void)?
    @Published private(set) var mode: Mode = .mostUsed
    /// Frozen for this opening except when a drag edits a key. Number keys
    /// address these slots, and an empty slot is a key with no emoji.
    private(set) var numberedSlots: [Emoji?] = Array(repeating: nil, count: numberSlotCount)
    var quickSuggestions: [Emoji] { numberedSlots.compactMap { $0 } }

    struct ShortcutItem: Identifiable, Equatable {
        let emoji: Emoji
        let key: Character
        var id: String { "\(key)-\(emoji.hexcode)" }
    }

    /// One grid cell. A numbered slot can be empty. A letter or number is the
    /// visible shortcut; `nil` means the emoji is shown with no key.
    struct PickerSlot: Identifiable, Equatable {
        let id: String
        let emoji: Emoji?
        let shortcut: String?
    }

    /// The whole picker, not one page: the 1–0 slots, then the
    /// current page of letters, then every remaining emoji with no key.
    @Published private(set) var pickerSlots: [PickerSlot] = []

    /// The shortcut row always starts with the stable 1–0 choices, followed by
    /// one page of single-letter choices from the current mode.
    var shortcutItems: [ShortcutItem] {
        var items: [ShortcutItem] = []
        for (offset, emoji) in numberedSlots.enumerated() {
            guard let emoji else { continue }
            items.append(ShortcutItem(emoji: emoji, key: Self.numberKeys[offset]))
        }
        return items + (shortcutPages.indices.contains(shortcutPageIndex) ? shortcutPages[shortcutPageIndex] : [])
    }
    static let shortcutLetterPageSize = 26
    static let letterBindingsKey = "mojito.letterBindings"
    /// Hexcodes the user has taken off the keyboard. They stay visible and
    /// are not given a new letter the next time the picker opens.
    static let releasedShortcutsKey = "mojito.releasedShortcuts"
    private(set) var letterBindings: [String: String] = [:]
    private var releasedHexes: Set<String> = []
    /// Letters the user dragged an emoji out of. They stay empty, and are not
    /// given to another emoji the next time the picker opens.
    private var releasedLetters: Set<Character> = []
    private let defaults: UserDefaults
    private var shortcutPages: [[ShortcutItem]] = []
    @Published private(set) var shortcutPageIndex: Int = 0
    var shortcutPageCount: Int { max(1, shortcutPages.count) }

    /// Pack ranked choices onto pages without ever relabelling a collision.
    /// Cached when the corpus changes, so keystrokes and rendering only read it.
    private func rebuildShortcutPages() {
        let excluded = Set(quickSuggestions.map(\.hexcode))
        var seen = Set<String>()
        var pages: [[ShortcutItem]] = []
        var keys: [Set<Character>] = []
        for emoji in current where !excluded.contains(emoji.hexcode) && seen.insert(emoji.hexcode).inserted {
            guard let canonical = EmojiLetterBindings.canonicalHex(emoji.hexcode), let value = letterBindings[canonical], let key = value.first else { continue }
            let page = keys.firstIndex(where: { !$0.contains(key) }) ?? pages.count
            if page == pages.count { pages.append([]); keys.append([]) }
            pages[page].append(ShortcutItem(emoji: emoji, key: key))
            keys[page].insert(key)
        }
        shortcutPages = pages
        publishPickerSlots()
    }

    private func publishPickerSlots() {
        var slots: [PickerSlot] = []
        var shown = Set<String>()
        for (offset, emoji) in numberedSlots.enumerated() {
            let label = String(Self.numberKeys[offset])
            if let emoji {
                slots.append(PickerSlot(id: emoji.hexcode, emoji: emoji, shortcut: label))
                shown.insert(emoji.hexcode)
            } else {
                slots.append(PickerSlot(id: "number-\(label)", emoji: nil, shortcut: label))
            }
        }
        let assigned = Dictionary(grouping: shortcutPages.first ?? [], by: \.key)
        for letter in Self.letterKeys {
            if let item = assigned[letter]?.first, shown.insert(item.emoji.hexcode).inserted {
                slots.append(PickerSlot(id: item.emoji.hexcode, emoji: item.emoji, shortcut: String(letter)))
            } else {
                slots.append(PickerSlot(id: "letter-\(letter)", emoji: nil, shortcut: String(letter)))
            }
        }
        func appendUnkeyed(_ emoji: Emoji) {
            guard shown.insert(emoji.hexcode).inserted else { return }
            slots.append(PickerSlot(id: emoji.hexcode, emoji: emoji, shortcut: nil))
        }
        for page in shortcutPages.dropFirst() {
            for item in page { appendUnkeyed(item.emoji) }
        }
        for emoji in current { appendUnkeyed(emoji) }
        if !current.isEmpty && slots.count < Self.minimumShortcutSlots {
            for emoji in flat where slots.count < Self.minimumShortcutSlots {
                appendUnkeyed(emoji)
            }
        }
        pickerSlots = slots
    }
    @Published var shortcutSelectedIndex: Int = 0
    /// Set only by arrow keys, so a pointer move never asks the grid to scroll.
    @Published var keyboardScrollIndex: Int?

    /// True while the explicit search field owns the next keystrokes.
    @Published private(set) var searchInputActive: Bool = false
    private let mostUsed: [Emoji]
    private let recentEmojis: [Emoji]
    var showsCategories: Bool { mode == .all && !isSearching }

    func selectMode(_ value: Mode) {
        guard value != mode || isSearching || searchInputActive else { return }
        mode = value
        categoryTarget = nil
        exitSearch(notify: false)
        shortcutPageIndex = 0
        shortcutSelectedIndex = 0
        onModeChange?()
        setActiveCategory(sections.first?.category ?? .smileysPeople)
    }

    func beginSearch() {
        guard !searchInputActive else { return }
        searchInputActive = true
        onSearchModeChange?(true)
    }

    func exitSearch(notify: Bool = true) {
        let wasActive = searchInputActive || !query.isEmpty
        searchInputActive = !supportsShortcuts
        query = ""
        current = computeCurrent()
        hoverIndex = nil
        selectedIndex = 0
        shortcutSelectedIndex = 0
        shortcutPageIndex = 0
        scrollTarget = 0
        selectionStale = false
        if notify && wasActive { onSearchModeChange?(false) }
    }

    func changeShortcutPage(by delta: Int) {
        shortcutPageIndex = min(max(0, shortcutPageIndex + delta), shortcutPageCount - 1)
        shortcutSelectedIndex = 0
    }

    func emojiForShortcut(_ key: Character) -> Emoji? {
        guard !searchInputActive else { return nil }
        if let index = Self.numberKeys.firstIndex(of: key) {
            return numberedSlots.indices.contains(index) ? numberedSlots[index] : nil
        }
        let lowered = String(key).lowercased()
        guard lowered.count == 1, let normalized = lowered.first else { return nil }
        return shortcutItems.first(where: { $0.key == normalized })?.emoji
    }

    /// Drop `sourceHex` onto another emoji. A keyed target takes or swaps that
    /// key. An emoji with no key is the unassigned area: the source loses its
    /// shortcut and the target does not gain one.
    func dropShortcut(from sourceHex: String, onto targetHex: String) {
        guard sourceHex != targetHex, database.byHexcode[sourceHex] != nil else { return }
        let sourceKey = visibleKey(for: sourceHex)
        let targetKey = visibleKey(for: targetHex)
        switch (sourceKey, targetKey) {
        case (_, nil):
            if let sourceKey { releaseKey(sourceKey) }
        case (nil, .number(let index)):
            placeNumber(index, on: sourceHex)
        case (nil, .letter(let letter)):
            placeLetter(letter, on: sourceHex)
        case (.number(let left), .number(let right)):
            numberedSlots.swapAt(left, right)
        case (.letter(let left), .letter(let right)):
            swapLetters(left, right, sourceHex, targetHex)
        case (.number(let index), .letter(let letter)):
            swapNumberAndLetter(number: index, letter: letter, numberHex: sourceHex, letterHex: targetHex)
        case (.letter(let letter), .number(let index)):
            swapNumberAndLetter(number: index, letter: letter, numberHex: targetHex, letterHex: sourceHex)
        }
        saveShortcutEdits()
        rebuildShortcutPages()
    }

    /// Drop onto the open area under the grid. Removes the source shortcut.
    func dropShortcutOnUnassigned(from sourceHex: String) {
        guard let sourceKey = visibleKey(for: sourceHex) else { return }
        releaseKey(sourceKey)
        saveShortcutEdits()
        rebuildShortcutPages()
    }

    /// Drop onto an empty number cell, which assigns that number.
    func dropShortcut(from sourceHex: String, ontoEmptyNumber index: Int) {
        guard numberedSlots.indices.contains(index), numberedSlots[index] == nil,
              database.byHexcode[sourceHex] != nil else { return }
        if let sourceKey = visibleKey(for: sourceHex) {
            vacate(sourceKey, hex: sourceHex)
        }
        placeNumber(index, on: sourceHex)
        saveShortcutEdits()
        rebuildShortcutPages()
    }

    /// Drop onto an empty letter cell, which assigns that letter and no other.
    func dropShortcut(from sourceHex: String, ontoEmptyLetter letter: Character) {
        guard database.byHexcode[sourceHex] != nil,
              !letterBindings.values.contains(String(letter)) else { return }
        if let sourceKey = visibleKey(for: sourceHex) {
            vacate(sourceKey, hex: sourceHex)
        }
        placeLetter(letter, on: sourceHex)
        saveShortcutEdits()
        rebuildShortcutPages()
    }

    private enum VisibleKey {
        case number(Int)
        case letter(Character)
    }

    private func visibleKey(for hex: String) -> VisibleKey? {
        if let index = numberedSlots.firstIndex(where: { $0?.hexcode == hex }) {
            return .number(index)
        }
        if let item = shortcutPages.first?.first(where: { $0.emoji.hexcode == hex }) {
            return .letter(item.key)
        }
        return nil
    }

    private func canonical(_ hex: String) -> String {
        EmojiLetterBindings.canonicalHex(hex) ?? hex
    }

    /// Remove a shortcut entirely. A letter is taken off every emoji that
    /// shared it, so it does not reappear on the next one down.
    private func releaseKey(_ key: VisibleKey) {
        switch key {
        case .number(let index):
            if let hex = numberedSlots[index]?.hexcode {
                releasedHexes.insert(canonical(hex))
                numberedSlots[index] = nil
            }
        case .letter(let letter):
            let token = String(letter)
            for (hex, value) in letterBindings where value == token {
                letterBindings.removeValue(forKey: hex)
                releasedHexes.insert(hex)
            }
            releasedLetters.insert(letter)
        }
    }

    /// Leave a key without marking its emoji as permanently unbound. Used
    /// when that emoji is about to receive a different key.
    private func vacate(_ key: VisibleKey, hex: String) {
        switch key {
        case .number(let index):
            if numberedSlots[index]?.hexcode == hex { numberedSlots[index] = nil }
        case .letter(let letter):
            letterBindings.removeValue(forKey: canonical(hex))
            releasedLetters.insert(letter)
        }
    }

    private func placeNumber(_ index: Int, on hex: String) {
        if let previous = numberedSlots[index]?.hexcode, previous != hex {
            releasedHexes.insert(canonical(previous))
            letterBindings.removeValue(forKey: canonical(previous))
        }
        for slot in numberedSlots.indices where slot != index && numberedSlots[slot]?.hexcode == hex {
            numberedSlots[slot] = nil
        }
        letterBindings.removeValue(forKey: canonical(hex))
        numberedSlots[index] = database.byHexcode[hex]
        releasedHexes.remove(canonical(hex))
    }

    private func placeLetter(_ letter: Character, on hex: String) {
        let token = String(letter)
        let owner = canonical(hex)
        for (key, value) in letterBindings where value == token && key != owner {
            letterBindings.removeValue(forKey: key)
            releasedHexes.insert(key)
        }
        for slot in numberedSlots.indices where numberedSlots[slot]?.hexcode == hex {
            numberedSlots[slot] = nil
        }
        letterBindings[owner] = token
        releasedHexes.remove(owner)
        releasedLetters.remove(letter)
    }

    private func swapLetters(_ left: Character, _ right: Character, _ source: String, _ target: String) {
        let sourceKey = canonical(source)
        let targetKey = canonical(target)
        stripLetter(left, except: targetKey)
        stripLetter(right, except: sourceKey)
        letterBindings[sourceKey] = String(right)
        letterBindings[targetKey] = String(left)
        releasedHexes.remove(sourceKey)
        releasedHexes.remove(targetKey)
        releasedLetters.remove(left)
        releasedLetters.remove(right)
    }

    private func swapNumberAndLetter(number index: Int, letter: Character, numberHex: String, letterHex: String) {
        let numberKey = canonical(numberHex)
        let letterKey = canonical(letterHex)
        stripLetter(letter, except: numberKey)
        letterBindings.removeValue(forKey: letterKey)
        letterBindings[numberKey] = String(letter)
        numberedSlots[index] = database.byHexcode[letterHex]
        releasedHexes.remove(numberKey)
        releasedHexes.remove(letterKey)
        releasedLetters.remove(letter)
    }

    private func stripLetter(_ letter: Character, except owner: String) {
        let token = String(letter)
        for (key, value) in letterBindings where value == token && key != owner {
            letterBindings.removeValue(forKey: key)
            releasedHexes.insert(key)
        }
    }

    private func saveShortcutEdits() {
        defaults.set(numberedSlots.map { $0?.hexcode ?? "" }, forKey: Self.numberedEmojiKey)
        defaults.set(letterBindings, forKey: Self.letterBindingsKey)
        defaults.set(Array(releasedHexes).sorted(), forKey: Self.releasedShortcutsKey)
        defaults.set(releasedLetters.map { String($0) }.sorted(), forKey: Self.releasedLettersKey)
    }

    /// A single emoji cell carrying its global flat index as its identity —
    /// the one id used for both `ForEach` and `scrollTo`. Avoiding a second
    /// (`.id()`) identity is what stops SwiftUI's lazy diff from keeping stale
    /// cells around and ghosting one section's glyphs over another's.
    struct Cell: Identifiable {
        let id: Int
        let emoji: Emoji
    }

    /// One category's worth of cells. `startIndex` is the global index of its
    /// first cell (used to park the keyboard selection on a tab jump).
    struct Section: Identifiable {
        let category: EmojiCategory
        let cells: [Cell]
        var id: EmojiCategory { category }
        var startIndex: Int { cells.first?.id ?? 0 }
        var indices: Range<Int> { startIndex..<(startIndex + cells.count) }
    }

    @Published private(set) var query: String = ""
    /// Section currently at the top of the scroll view — drives the tab
    /// highlight. Backed by a Combine subject (not `@Published`) so the
    /// scroll-driven updates from `onPreferenceChange` don't invalidate the
    /// `InlineBrowserView` body and re-evaluate the `ScrollView`/`LazyVGrid`
    /// mid-scroll — on macOS 27 beta 1 that re-eval visibly snapped the scroll
    /// position back to the top when crossing a section boundary. The tab bar
    /// subscribes to `activeCategoryPublisher` via `.onReceive` and holds its
    /// own local highlight state instead.
    private let activeCategorySubject: CurrentValueSubject<EmojiCategory, Never>
    let activeCategoryPublisher: AnyPublisher<EmojiCategory, Never>
    var activeCategory: EmojiCategory { activeCategorySubject.value }
    @Published var selectedIndex: Int = 0
    /// Cell the mouse is currently hovering over. Plain (non-`@Published`)
    /// storage so cells passing under a stationary cursor during a slow scroll
    /// don't invalidate the `InlineBrowserView` body and reset the scroll
    /// position. `selectedEmoji` prefers this over `selectedIndex` so
    /// hover-then-Enter still inserts the hovered cell.
    var hoverIndex: Int?
    /// Flat cell index to scroll into view (keyboard nav / reset to top). The
    /// view clears it to nil after handling so the same index can repeat.
    @Published var scrollTarget: Int?
    /// Category section to jump to (tab tap). Cleared by the view after the
    /// jump so the same tab can be tapped twice.
    @Published var categoryTarget: EmojiCategory?

    private let database: EmojiDatabase
    private let usage: [String: Int]
    private let symbolsEnabled: Bool
    private let contextual: [Emoji]
    private let hasContextSuggestions: Bool

    /// This key intentionally stays literal: it is a user preference shared
    /// by the compact pill and the full browser, rather than a transient
    /// browser setting that belongs in the generated PrefsKey list.
    static let numberedEmojiKey = "mojito.numberedEmoji"

    /// Sections in display order (only those with content).
    let sections: [Section]
    /// Every emoji, in section order — the flat list keyboard nav addresses.
    private let flat: [Emoji]

    var visibleCategories: [EmojiCategory] { sections.map(\.category) }

    /// `includeSymbols` forces the symbol corpus in regardless of the global
    /// Symbols toggle — the alias picker always offers symbols as alias targets.
    init(database: EmojiDatabase, quickAccess: QuickAccessStore, includeSymbols: Bool = false, defaults: UserDefaults = .standard, contextText: String? = nil) {
        self.database = database
        self.defaults = defaults
        self.supportsShortcuts = !includeSymbols
        self.searchInputActive = includeSymbols
        self.usage = (defaults.dictionary(forKey: PrefsKey.usageCounts) as? [String: Int]) ?? [:]
        // Symbols-on now lives in the trigger config (the legacy
        // `symbolsEnabled` key is no longer written by Settings).
        self.symbolsEnabled = TriggerConfigStore.load(defaults: defaults).symbols.enabled || includeSymbols
        let built = Self.build(database: database, quickAccess: quickAccess, usage: self.usage, symbolsEnabled: self.symbolsEnabled)
        self.sections = built
        let flat = built.flatMap { $0.cells.map(\.emoji) }
        self.flat = flat
        let usageSnapshot = self.usage
        let ranked = database.all.filter { usageSnapshot[$0.hexcode, default: 0] > 0 }
            .sorted {
                let a = usageSnapshot[$0.hexcode, default: 0]
                let b = usageSnapshot[$1.hexcode, default: 0]
                return a != b ? a > b : $0.hexcode < $1.hexcode
            }
        self.mostUsed = ranked
        let candidates = ranked + QuickAccess.resolved(store: quickAccess, database: database, usage: self.usage)
        var quickSeen = Set<String>()
        let fallbackQuick = Array(candidates.filter { quickSeen.insert($0.hexcode).inserted }.prefix(Self.numberSlotCount))
        let released = Set((defaults.stringArray(forKey: Self.releasedShortcutsKey) ?? []).compactMap {
            EmojiLetterBindings.canonicalHex($0)
        })
        self.releasedHexes = released
        let blockedLetters = Set((defaults.stringArray(forKey: Self.releasedLettersKey) ?? []).compactMap(\.first))
        self.releasedLetters = blockedLetters
        let rawNumbers = defaults.stringArray(forKey: Self.numberedEmojiKey) ?? []
        var slots: [Emoji?] = []
        if rawNumbers.isEmpty {
            var stableSeen = Set<String>()
            for emoji in fallbackQuick where slots.count < Self.numberSlotCount && stableSeen.insert(emoji.hexcode).inserted {
                slots.append(emoji)
            }
        } else {
            for value in rawNumbers.prefix(Self.numberSlotCount) {
                slots.append(value.isEmpty ? nil : database.byHexcode[value])
            }
            if rawNumbers.count < Self.numberSlotCount {
                var stableSeen = Set(slots.compactMap { $0?.hexcode })
                for emoji in fallbackQuick where slots.count < Self.numberSlotCount {
                    let hex = EmojiLetterBindings.canonicalHex(emoji.hexcode) ?? emoji.hexcode
                    if released.contains(hex) || !stableSeen.insert(emoji.hexcode).inserted { continue }
                    slots.append(emoji)
                }
            }
        }
        while slots.count < Self.numberSlotCount { slots.append(nil) }
        self.numberedSlots = Array(slots.prefix(Self.numberSlotCount))
        let numbered = Set(self.numberedSlots.compactMap { $0?.hexcode })
        var savedLetters = (defaults.dictionary(forKey: Self.letterBindingsKey) as? [String: String]) ?? [:]
        for hex in released { savedLetters.removeValue(forKey: hex) }
        self.letterBindings = EmojiLetterBindings.resolve(
            candidates: (ranked + flat).filter {
                !numbered.contains($0.hexcode)
                    && !released.contains(EmojiLetterBindings.canonicalHex($0.hexcode) ?? $0.hexcode)
            },
            saved: savedLetters,
            blocked: blockedLetters)
        var seen = Set<String>()
        self.recentEmojis = (defaults.stringArray(forKey: PrefsKey.recentEmoji) ?? [])
            .filter { seen.insert($0).inserted }
            .compactMap { database.byHexcode[$0] }
        let contextual = Self.contextualMatches(in: database, text: contextText, usage: self.usage)
        self.contextual = contextual
        self.hasContextSuggestions = !contextual.isEmpty
        self.current = includeSymbols || (ranked.isEmpty && contextual.isEmpty) ? flat : (contextual.isEmpty ? ranked : contextual + ranked.filter { !contextual.contains($0) })
        self.mode = includeSymbols || (ranked.isEmpty && contextual.isEmpty) ? .all : (contextual.isEmpty ? .mostUsed : .suggested)
        let subject = CurrentValueSubject<EmojiCategory, Never>(built.first?.category ?? .smileysPeople)
        self.activeCategorySubject = subject
        self.activeCategoryPublisher = subject.eraseToAnyPublisher()
        rebuildShortcutPages()
    }

    /// The addressable list for selection + keyboard nav: search results when
    /// searching, else the whole library in section order. Cached — recomputed
    /// only when the query changes (setQuery/selectCategory). The view body
    /// reads it several times per render, so it must not re-run the fuzzy
    /// search on each access.
    @Published private(set) var current: [Emoji] {
        didSet { rebuildShortcutPages() }
    }

    private func computeCurrent() -> [Emoji] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            switch mode {
            case .suggested:
                return contextual + mostUsed.filter { !contextual.contains($0) }
            case .mostUsed: return mostUsed
            case .recent: return recentEmojis
            case .all: return flat
            }
        }
        return FuzzyMatcher.search(
            query: trimmed, in: database, usage: usage,
            corpus: symbolsEnabled ? .emojiAndSymbols : .emojiOnly,
            useFrequencyBoost: true, limit: 240
        )
        .map(\.emoji)
        // Keep real emoji + symbols; drop egg/sentinel rows.
        .filter { database.byHexcode[$0.hexcode] != nil || $0.hexcode.hasPrefix("SYM_") }
    }

    /// Exact local keyword/tag matching. This deliberately avoids NLP and
    /// network calls: words in the last bounded context are matched against
    /// the emoji's existing shortcodes, label, and tags.
    static func contextualMatches(in database: EmojiDatabase, text: String?, usage: [String: Int]) -> [Emoji] {
        guard let text, !text.isEmpty else { return [] }
        let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "have", "your", "you", "are", "was", "but", "not", "just", "like", "can", "will", "would", "about", "into", "then", "than", "what", "when", "where", "how", "why", "its", "it's"]
        let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !stop.contains($0) })
        guard !words.isEmpty else { return [] }
        let scored: [(Emoji, Int)] = database.all.compactMap { emoji in
            let fields = database.contextWords[emoji.hexcode] ?? []
            let score = words.reduce(0) { $0 + (fields.contains($1) ? 1 : 0) }
            return score > 0 ? (emoji, score) : nil
        }
        return scored.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            let ua = usage[$0.0.hexcode, default: 0], ub = usage[$1.0.hexcode, default: 0]
            return ua != ub ? ua > ub : $0.0.hexcode < $1.0.hexcode
        }.prefix(8).map(\.0)
    }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedEmoji: Emoji? {
        if supportsShortcuts && !searchInputActive {
            guard pickerSlots.indices.contains(shortcutSelectedIndex) else { return pickerSlots.compactMap(\.emoji).first }
            return pickerSlots[shortcutSelectedIndex].emoji
        }
        let items = current
        if let h = hoverIndex, items.indices.contains(h) { return items[h] }
        guard items.indices.contains(selectedIndex) else { return items.first }
        return items[selectedIndex]
    }

    func setQuery(_ newQuery: String) {
        if !newQuery.trimmingCharacters(in: .whitespaces).isEmpty { beginSearch() }
        hoverIndex = nil
        query = newQuery
        current = computeCurrent()
        selectedIndex = 0
        shortcutSelectedIndex = 0
        shortcutPageIndex = 0
        scrollTarget = 0  // back to top on every query change
        selectionStale = false
    }

    /// Tab tap: jump the scroll view to that category's section. Clears any
    /// search and parks the keyboard selection at the section's first cell.
    func selectCategory(_ category: EmojiCategory) {
        let wasSearching = isSearching || searchInputActive
        mode = .all
        hoverIndex = nil
        query = ""
        searchInputActive = !supportsShortcuts
        if wasSearching { onSearchModeChange?(false) }
        shortcutPageIndex = 0
        shortcutSelectedIndex = 0
        current = computeCurrent()  // → whole library
        if let section = sections.first(where: { $0.category == category }) {
            selectedIndex = section.startIndex
            if supportsShortcuts, let first = section.cells.first?.emoji,
               let index = pickerSlots.firstIndex(where: { $0.emoji?.hexcode == first.hexcode }) {
                shortcutSelectedIndex = index
            }
        }
        // If we were searching the list was a flat result grid; rebuilding the
        // sectioned list first, then jumping, keeps the target laid out.
        setActiveCategory(category)
        categoryTarget = category
        selectionStale = false  // tab tap is an explicit selection action
        if wasSearching { scrollTarget = nil }
    }

    private func setActiveCategory(_ value: EmojiCategory) {
        guard activeCategorySubject.value != value else { return }
        activeCategorySubject.send(value)
    }

    /// True iff the viewport has scrolled to a different section since the
    /// last `move`/`selectCategory`/`setQuery`. Drives the one-shot resync in
    /// `move(_:)` so an arrow press after a mouse scroll lands where the user
    /// is looking instead of snapping back to where the selection happens to be.
    private var selectionStale: Bool = false
    /// Timestamp of the last `move(_:)` — used by `updateActiveCategory` to
    /// suppress `selectionStale` during the scroll animation triggered by that
    /// move. Otherwise a section transition mid-animation, with `activeCategory`
    /// lagging one section behind `selectedIndex`, flags stale and a quick
    /// second arrow press resyncs back — observed as an intermittent wrap.
    private var lastMoveAt: Date = .distantPast

    func move(_ direction: GifMoveDirection) {
        if supportsShortcuts && !searchInputActive {
            let count = pickerSlots.count
            guard count > 0 else { return }
            let delta: Int
            switch direction {
            case .left: delta = -1
            case .right: delta = 1
            case .up: delta = -Self.shortcutColumns
            case .down: delta = Self.shortcutColumns
            }
            hoverIndex = nil
            shortcutSelectedIndex = min(max(0, shortcutSelectedIndex + delta), count - 1)
            keyboardScrollIndex = shortcutSelectedIndex
            return
        }
        let count = current.count
        guard count > 0 else { return }
        lastMoveAt = Date()
        // Only resync the selection if the user has mouse-scrolled the viewport
        // away from where the selection lives since the last selection action.
        // `selectionStale` is flipped by scroll-driven `setActiveCategory`; a
        // resync here just from `move()` would race the scroll-driven category
        // update and snap the selection back to the previous section.
        if showsCategories, selectionStale,
           let active = sections.first(where: { $0.category == activeCategory }),
           !active.indices.contains(selectedIndex)
        {
            selectedIndex = active.startIndex
            scrollTarget = selectedIndex
            selectionStale = false
            return
        }
        selectionStale = false
        let prev = selectedIndex
        // Search results are one flat grid (no headers), so simple column
        // stepping lands directly above/below.
        if !showsCategories {
            var next = selectedIndex
            switch direction {
            case .left:  next -= 1
            case .right: next += 1
            case .up:    next -= Self.columns
            case .down:  next += Self.columns
            }
            selectedIndex = min(max(next, 0), count - 1)
        } else {
            // Sectioned grid: every section header starts a fresh row, so the
            // flat index resets to column 0 at each seam. Step ↑/↓ by column,
            // not by a flat ±8, so the selection tracks straight up/down.
            selectedIndex = sectionedTarget(from: selectedIndex, direction: direction)
        }
        // Only fire the scroll target when the selection actually changed —
        // otherwise a held arrow key at the top/bottom edge re-fires
        // `scrollTo(0, .top)` every tick and the viewport visibly jitters.
        if selectedIndex != prev {
            scrollTarget = selectedIndex
        }
    }

    /// Column-preserving ↑/↓ (and clamped flat ←/→) across the sectioned grid.
    private func sectionedTarget(from index: Int, direction: GifMoveDirection) -> Int {
        let cols = Self.columns
        guard let s = sections.firstIndex(where: {
            index >= $0.startIndex && index < $0.startIndex + $0.cells.count
        }) else { return index }
        let section = sections[s]
        let local = index - section.startIndex
        let column = local % cols

        switch direction {
        case .left:
            return max(index - 1, 0)
        case .right:
            return min(index + 1, flat.count - 1)
        case .down:
            if local + cols < section.cells.count {
                return index + cols  // next row, same section
            }
            guard s + 1 < sections.count else { return index }
            let next = sections[s + 1]
            return next.startIndex + min(column, next.cells.count - 1)
        case .up:
            if local >= cols {
                return index - cols  // previous row, same section
            }
            guard s > 0 else { return index }
            let prev = sections[s - 1]
            let lastRowStart = ((prev.cells.count - 1) / cols) * cols
            return prev.startIndex + min(lastRowStart + column, prev.cells.count - 1)
        }
    }

    /// Mouse pick: snap the selection to the clicked glyph.
    func select(_ emoji: Emoji) {
        hoverIndex = nil
        if let index = pickerSlots.firstIndex(where: { $0.emoji?.hexcode == emoji.hexcode }) {
            shortcutSelectedIndex = index
        }
        if let idx = current.firstIndex(where: { $0.hexcode == emoji.hexcode }) {
            selectedIndex = idx
        }
    }

    /// Update the active tab from live section-header offsets (in the scroll
    /// view's coordinate space). The active section is the last header that has
    /// reached / passed the top edge. Headers below the fold (and ones recycled
    /// off the top) simply aren't in `offsets`; when none qualifies we keep the
    /// current tab rather than snapping to whatever header happens to be onscreen.
    func updateActiveCategory(from offsets: [EmojiCategory: CGFloat]) {
        guard showsCategories, !offsets.isEmpty else { return }
        let threshold: CGFloat = 1
        let atOrAboveTop = offsets.filter { $0.value <= threshold }
        guard let active = atOrAboveTop.max(by: { $0.value < $1.value })?.key else { return }
        let changed = active != activeCategorySubject.value
        setActiveCategory(active)
        // Mark the selection stale only when the user has scrolled into a
        // section that does NOT already contain `selectedIndex`, AND the scroll
        // isn't the tail of an arrow-key animation. Arrow-induced scrolls
        // animate over ~hundreds of ms; if `activeCategory` lags `selectedIndex`
        // by one section during that window, we'd flag stale and a quick second
        // arrow press would resync — observed as an intermittent wrap-to-top.
        // The `Date()` read is deferred behind `changed` because most scroll
        // frames don't transition section.
        guard changed,
              let section = sections.first(where: { $0.category == active }),
              !section.indices.contains(selectedIndex),
              Date().timeIntervalSince(lastMoveAt) >= 0.75
        else { return }
        selectionStale = true
    }

    private static func build(
        database: EmojiDatabase,
        quickAccess: QuickAccessStore,
        usage: [String: Int],
        symbolsEnabled: Bool
    ) -> [Section] {
        var sections: [Section] = []
        var cursor = 0

        func add(_ category: EmojiCategory, _ emoji: [Emoji]) {
            guard !emoji.isEmpty else { return }
            let cells = emoji.enumerated().map { Cell(id: cursor + $0.offset, emoji: $0.element) }
            sections.append(Section(category: category, cells: cells))
            cursor += emoji.count
        }

        // Personal history has its own mode; All contains each category once.

        for category in EmojiCategory.allCases where !category.isDynamic {
            let groups = Set(category.groups)
            add(category, database.all.filter { groups.contains($0.group) })
        }

        // Typographic symbols (★ ⌘ ⌥ …) only when enabled — the CoreText sweep
        // is slow and the corpus is large. Forced on in the alias picker so a
        // symbol can be chosen as an alias target.
        if symbolsEnabled {
            add(.specialCharacters, SymbolsDatabase.indexed().map(\.emoji))
        }
        return sections
    }
}
