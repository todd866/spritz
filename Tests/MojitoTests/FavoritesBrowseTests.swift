import Testing
import Foundation
@testable import Mojito

/// State-machine behavior for the favorites pill + in-panel browser (W-295).
/// The pill only claims navigation keys once `emptyPickerActive` is set (the
/// Engine flips it after the show), so a `:` followed by a fast keystroke
/// never hijacks the keyboard.
struct TriggerStateMachineBrowseTests {

    @Test func bareColonStaysInert() {
        var sm = TriggerStateMachine()  // no trigger char set
        let out = sm.handle(.colon)
        #expect(out.action == .none)
        #expect(sm.state == .capturing(query: ""))
    }

    @Test func triggerCharOpensPillAndSwallowsIt() {
        var sm = TriggerStateMachine()
        sm.quickAccessTrigger = "?"
        let colon = sm.handle(.colon)
        #expect(colon.action == .none)
        let q = sm.handle(.cancelChar("?"))
        #expect(q.action == .openPicker(query: "", scope: .normal))
        #expect(q.consumesKey == true)
        #expect(sm.state == .capturing(query: ""))
    }

    @Test func customTriggerCharOpensPill() {
        var sm = TriggerStateMachine()
        sm.quickAccessTrigger = ";"
        _ = sm.handle(.colon)
        let semi = sm.handle(.cancelChar(";"))
        #expect(semi.action == .openPicker(query: "", scope: .normal))
        #expect(semi.consumesKey == true)
    }

    @Test func questionMarkIsLiteralWhenTriggerOff() {
        var sm = TriggerStateMachine()  // no trigger char
        _ = sm.handle(.colon)
        let q = sm.handle(.cancelChar("?"))
        #expect(q.action == .checkEmoticon(query: "", terminator: "?"))
    }

    @Test func arrowsPassThroughUntilPillVisible() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        let down = sm.handle(.arrowDown)
        #expect(down.action == .none)
        #expect(down.consumesKey == false)
    }

    @Test func returnIsLiteralUntilPillVisible() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        let ret = sm.handle(.returnKey(shift: false))
        #expect(ret.action == .closePicker)
        #expect(ret.consumesKey == false)
    }

    @Test func visiblePillNavigatesAndExpands() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true

        let right = sm.handle(.arrowRight)
        #expect(right.action == .moveSelection(delta: 1))
        #expect(right.consumesKey == true)
        let left = sm.handle(.arrowLeft)
        #expect(left.action == .moveSelection(delta: -1))
        #expect(left.consumesKey == true)

        // Both ↑ and ↓ expand into the full grid.
        let up = sm.handle(.arrowUp)
        #expect(up.action == .expandBrowser)
        #expect(up.consumesKey == true)
        let down = sm.handle(.arrowDown)
        #expect(down.action == .expandBrowser)
        #expect(down.consumesKey == true)
    }

    @Test func pillDigitQuickPicks() {
        var sm = TriggerStateMachine()
        sm.quickAccessTrigger = "?"
        _ = sm.handle(.colon)
        _ = sm.handle(.cancelChar("?"))
        sm.emptyPickerActive = true
        sm.pillEmojiCount = 8
        let three = sm.handle(.nameChar("3"))
        #expect(three.action == .pickIndex(2))  // 1-based digit → 0-based index
        #expect(three.consumesKey == true)
    }

    @Test func pillOutOfRangeDigitStartsSearch() {
        var sm = TriggerStateMachine()
        sm.quickAccessTrigger = "?"
        _ = sm.handle(.colon)
        _ = sm.handle(.cancelChar("?"))
        sm.emptyPickerActive = true
        sm.pillEmojiCount = 2  // only two favorites shown
        let five = sm.handle(.nameChar("5"))
        // Beyond the row count → not a quick-pick; the digit falls through to a
        // normal search instead of being swallowed.
        #expect(five.action == .closePicker)
        #expect(sm.state == .capturing(query: "5"))
    }

    @Test func pillLetterStillStartsSearch() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true
        let out = sm.handle(.nameChar("a"))
        #expect(out.action == .closePicker)  // a non-digit dismisses to search
        #expect(sm.state == .capturing(query: "a"))
    }

    @Test func questionPillEscapeRestoresQuestionMark() {
        var sm = TriggerStateMachine()
        sm.quickAccessTrigger = "?"
        _ = sm.handle(.colon)
        _ = sm.handle(.cancelChar("?"))
        sm.emptyPickerActive = true
        let esc = sm.handle(.escape)
        #expect(esc.action == .closePickerRestoringTrigger("?"))
        #expect(esc.consumesKey == true)
        #expect(sm.state == .idle)
    }

    @Test func pillEscapeIsPlainCloseWhenTriggerOff() {
        var sm = TriggerStateMachine()  // no trigger char → nothing to restore
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true
        let esc = sm.handle(.escape)
        #expect(esc.action == .closePicker)
    }

    @Test func visiblePillReturnInsertsSelected() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true
        let ret = sm.handle(.returnKey(shift: false))
        #expect(ret.action == .insertEmoji(query: "", mode: .fromPicker, scope: .normal))
        #expect(ret.consumesKey == true)
        #expect(sm.state == .idle)
    }

    @Test func normalThresholdStillOpensAfterFavoritesDismissal() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true
        _ = sm.handle(.nameChar("s"))
        let out = sm.handle(.nameChar("o"))
        #expect(out.action == .openPicker(query: "so", scope: .normal))
    }

    @Test func arrowSideKeysEndCaptureWhenPillNotVisible() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        let left = sm.handle(.arrowLeft)
        #expect(left.action == .closePicker)
        #expect(left.consumesKey == false)
        #expect(sm.state == .idle)
    }

    @Test func resetClearsEmptyPickerFlag() {
        var sm = TriggerStateMachine()
        _ = sm.handle(.colon)
        sm.emptyPickerActive = true
        sm.reset()
        #expect(sm.emptyPickerActive == false)
        #expect(sm.state == .idle)
    }

    // MARK: in-panel browser routing

    @Test func browsingRoutesTypingNavAndPick() {
        var sm = TriggerStateMachine()
        sm.enterBrowsing(query: "")
        #expect(sm.state == .browsing(query: ""))
        sm.setBrowserSearchInputActive(true)

        let c = sm.handle(.nameChar("c"))
        #expect(c.action == .refreshBrowser(query: "c"))
        #expect(c.consumesKey == true)
        _ = sm.handle(.nameChar("a"))
        let space = sm.handle(.cancelChar(" "))
        #expect(space.action == .refreshBrowser(query: "ca "))

        let down = sm.handle(.arrowDown)
        #expect(down.action == .moveBrowser(direction: .down))
        #expect(down.consumesKey == true)

        let pick = sm.handle(.returnKey(shift: false))
        #expect(pick.action == .pickBrowser(keepOpen: false))
        #expect(pick.consumesKey == true)
        #expect(sm.state == .idle)
    }

    @Test func browsingBackspacePastEmptyStaysOpen() {
        var sm = TriggerStateMachine()
        sm.enterBrowsing(query: "a")
        _ = sm.handle(.backspace)
        for _ in 0..<3 {
            let extra = sm.handle(.backspace)
            #expect(extra.action == TriggerAction.none)
            #expect(extra.consumesKey == true)
        }
        #expect(sm.state == .browsing(query: ""))
    }

    @Test func browserNumberPicksOnlyBeforeSearch() {
        var sm = TriggerStateMachine()
        sm.enterBrowsing(query: "")
        let pick = sm.handle(.nameChar("3"))
        #expect(pick.action == .pickBrowserShortcut(key: "3"))
        #expect(pick.consumesKey)
        // Engine closes only after resolving an available slot.
        #expect(sm.state == .browsing(query: ""))
        sm.setBrowserSearchInputActive(true)
        _ = sm.handle(.nameChar("h"))
        #expect(sm.handle(.nameChar("3")).action == .refreshBrowser(query: "h3"))
        sm.enterBrowsing(query: "")
        #expect(sm.handle(.nameChar("9")).action == .pickBrowserShortcut(key: "9"))
    }

    @Test func browsingEscapeCloses() {
        var sm = TriggerStateMachine()
        sm.enterBrowsing(query: "ab")
        let esc = sm.handle(.escape)
        #expect(esc.action == .closeBrowser)
        #expect(esc.consumesKey == true)
        #expect(sm.state == .idle)
    }
}

struct EmojiLetterBindingsTests {
    private func emoji(_ hex: String, _ label: String, _ shortcodes: [String] = []) -> Emoji {
        Emoji(hexcode: hex, character: "🙂", label: label, shortcodes: shortcodes,
              tags: [], group: 0, order: 0)
    }

    @Test func preservesSavedBindingsAndUsesMnemonics() {
        let heart = emoji("2764-FE0F", "red heart", ["heart"])
        let pirate = emoji("1F3F4-200D-2620-FE0F", "skull and crossbones", ["pirate"])
        let result = EmojiLetterBindings.resolve(
            candidates: [heart, pirate],
            saved: ["2764-fe0f": "z", "not-a-hex": "q"]
        )
        #expect(result["2764-FE0F"] == "z")
        #expect(result["1F3F4-200D-2620-FE0F"] == "p")
        #expect(result["not-a-hex"] == nil)
    }

    @Test func firstTwentySixNewBindingsAreUnique() {
        let candidates = (0..<26).map {
            emoji(String(format: "1000-%02X", $0), "item \($0)")
        }
        let result = EmojiLetterBindings.resolve(candidates: candidates, saved: [:])
        #expect(result.count == 26)
        #expect(Set(result.values).count == 26)
    }

    @Test func invalidSavedValuesAreDiscardedAndLaterEntriesRemainCovered() {
        let candidates = (0..<52).map { emoji(String(format: "2000-%02X", $0), "emoji \($0)") }
        let result = EmojiLetterBindings.resolve(
            candidates: candidates,
            saved: ["2000-00": "AB", "2000-01": "é", "2000-02": "Q"]
        )
        #expect(result.count == 52)
        #expect(result["2000-00"] != nil)
        #expect(result["2000-01"] != nil)
        #expect(result["2000-02"] == "q")
        #expect(result.values.allSatisfy {
            guard $0.unicodeScalars.count == 1, let scalar = $0.unicodeScalars.first else { return false }
            return scalar.value >= 97 && scalar.value <= 122
        })
    }

    @Test func preservesOpaqueSymbolIdentifiers() {
        let symbol = emoji("SYM_command", "command")
        let result = EmojiLetterBindings.resolve(candidates: [symbol], saved: ["SYM_command": "k"])
        #expect(result["SYM_command"] == "k")
    }
}

@MainActor
struct QuickAccessStoreTests {
    private func makeStore() -> QuickAccessStore {
        let suite = UserDefaults(suiteName: "mojito.tests.quickaccess.\(UUID().uuidString)")!
        return QuickAccessStore(defaults: suite)
    }

    @Test func startsAllAuto() {
        let store = makeStore()
        #expect(store.slots.count == QuickAccessStore.slotCount)
        #expect(store.slots.allSatisfy { $0 == nil })
        #expect(!store.hasPins)
    }

    @Test func pinResetAndDedup() {
        let store = makeStore()
        store.pin("1F600", at: 0)
        #expect(store.slots[0] == "1F600")
        #expect(store.hasPins)
        // Re-pinning the same glyph elsewhere clears the old slot.
        store.pin("1F600", at: 3)
        #expect(store.slots[0] == nil)
        #expect(store.slots[3] == "1F600")
        store.reset(at: 3)
        #expect(store.slots[3] == nil)
        #expect(!store.hasPins)
    }

    @Test func resetAllClearsPins() {
        let store = makeStore()
        store.pin("A", at: 1)
        store.pin("B", at: 2)
        store.resetAll()
        #expect(store.slots.allSatisfy { $0 == nil })
    }

    @Test func persistsAcrossInstances() {
        let suiteName = "mojito.tests.quickaccess.persist.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let first = QuickAccessStore(defaults: suite)
        first.pin("2764", at: 2)
        let second = QuickAccessStore(defaults: suite)
        #expect(second.slots[2] == "2764")
        #expect(second.slots.filter { $0 != nil }.count == 1)
    }

    @Test func resolvedKeepsPinAtSlotAndAutoFillsMostUsed() {
        let db = EmojiDatabase.shared
        guard db.all.count >= 3 else { return }
        let store = makeStore()
        let pin = db.all[0].hexcode
        let a = db.all[1].hexcode
        let b = db.all[2].hexcode
        store.pin(pin, at: 1)
        // slot 0 auto → top most-used (b:10), slot 1 pinned, slot 2 auto → next (a:3)
        let resolved = QuickAccess.resolved(store: store, database: db, usage: [a: 3, b: 10]).map(\.hexcode)
        #expect(resolved.count >= 3)
        #expect(resolved[0] == b)
        #expect(resolved[1] == pin)
        #expect(resolved[2] == a)
    }

    @Test func resolvedExcludesPinnedFromAutoFill() {
        let db = EmojiDatabase.shared
        guard db.all.count >= 1 else { return }
        let store = makeStore()
        let x = db.all[0].hexcode
        store.pin(x, at: 0)
        // x is also the most-used — it must not also appear in an auto slot.
        let resolved = QuickAccess.resolved(store: store, database: db, usage: [x: 99]).map(\.hexcode)
        #expect(resolved.filter { $0 == x }.count == 1)
    }

    @Test func resolvedIsDeterministic() {
        let db = EmojiDatabase.shared
        guard db.all.count >= 2 else { return }
        let store = makeStore()
        let x = db.all[0].hexcode
        let y = db.all[1].hexcode
        let usage = [x: 5, y: 5]
        let first = QuickAccess.resolved(store: store, database: db, usage: usage).map(\.hexcode)
        let second = QuickAccess.resolved(store: store, database: db, usage: usage).map(\.hexcode)
        #expect(first == second)
        #expect(Array(first.prefix(2)) == [min(x, y), max(x, y)])
    }
}


@MainActor
struct PersonalBrowserTests {
    @Test func shortcutSelectionTracksArrowsAndSearchUsesSevenColumns() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            #expect(browser.shortcutSelectedIndex == 0)
            #expect(browser.selectedEmoji?.hexcode == browser.shortcutItems.first?.emoji.hexcode)
            browser.move(.right)
            #expect(browser.shortcutSelectedIndex == 1)
            #expect(browser.selectedEmoji?.hexcode == browser.shortcutItems[1].emoji.hexcode)

            browser.beginSearch()
            browser.setQuery("")
            browser.move(.down)
            #expect(browser.selectedIndex == 7)
        }
    }

    @Test func selectingNumberedItemWorksEvenWhenModeListOmitsIt() {
        withDefaults { defaults in
            let db = EmojiDatabase.shared
            guard let numbered = db.all.first else { return }
            defaults.set([numbered.hexcode], forKey: EmojiBrowserViewModel.numberedEmojiKey)
            let browser = model(defaults)
            #expect(browser.emojiForShortcut("1")?.hexcode == numbered.hexcode)
            browser.select(numbered)
            #expect(browser.shortcutSelectedIndex == 0)
            #expect(browser.selectedEmoji?.hexcode == numbered.hexcode)
        }
    }

    @Test func singleKeyShortcutsExposeStableNumbersAndPagedLetters() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            #expect(browser.shortcutItems.prefix(10).map(\.key) == Array("1234567890"))
            #expect(browser.emojiForShortcut("1")?.hexcode == browser.quickSuggestions.first?.hexcode)
            #expect(browser.emojiForShortcut("0")?.hexcode == browser.numberedSlots[9]?.hexcode)
            #expect(browser.shortcutItems.count <= 36)
            for page in 0..<browser.shortcutPageCount {
                if page > 0 { browser.changeShortcutPage(by: 1) }
                let items = browser.shortcutItems
                #expect(Set(items.map(\.key)).count == items.count)
                for item in items {
                    #expect(browser.emojiForShortcut(item.key)?.hexcode == item.emoji.hexcode)
                    #expect(browser.emojiForShortcut(Character(String(item.key).uppercased()))?.hexcode == item.emoji.hexcode)
                }
            }
        }
    }

    @Test func mnemonicBindingsSurviveUsageChangesAndModes() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(60))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map { ($0.element.hexcode, 100 - $0.offset) }), forKey: PrefsKey.usageCounts)
            let first = model(defaults)
            defaults.set(first.quickSuggestions.map(\.hexcode), forKey: EmojiBrowserViewModel.numberedEmojiKey)
            defaults.set(first.letterBindings, forKey: EmojiBrowserViewModel.letterBindingsKey)
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map { ($0.element.hexcode, 1 + $0.offset) }), forKey: PrefsKey.usageCounts)
            defaults.set(sample.reversed().map(\.hexcode), forKey: PrefsKey.recentEmoji)
            let reopened = model(defaults)
            #expect(reopened.letterBindings == first.letterBindings)
            for mode in [EmojiBrowserViewModel.Mode.mostUsed, .recent, .all] {
                reopened.selectMode(mode)
                var covered = Set<String>()
                for page in 0..<reopened.shortcutPageCount {
                    if page > 0 { reopened.changeShortcutPage(by: 1) }
                    let items = reopened.shortcutItems
                    #expect(Set(items.map(\.key)).count == items.count)
                    for item in items.dropFirst(reopened.quickSuggestions.count) {
                        #expect(String(item.key) == first.letterBindings[item.emoji.hexcode])
                        covered.insert(item.emoji.hexcode)
                    }
                }
                let numbered = Set(reopened.quickSuggestions.map(\.hexcode))
                #expect(covered == Set(reopened.current.map(\.hexcode)).subtracting(numbered))
            }
        }
    }

    @Test func searchIsExplicitAndExitRestoresShortcutMode() {
        withDefaults { defaults in
            defaults.set(["1F602": 5], forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            var changes: [Bool] = []
            browser.onSearchModeChange = { changes.append($0) }
            #expect(!browser.searchInputActive)
            browser.beginSearch()
            #expect(browser.searchInputActive)
            browser.setQuery("rocket")
            #expect(browser.isSearching)
            browser.exitSearch()
            #expect(!browser.searchInputActive)
            #expect(browser.query.isEmpty)
            #expect(changes == [true, false])
            #expect(browser.emojiForShortcut("1")?.hexcode == browser.quickSuggestions.first?.hexcode)
        }
    }

    @Test func numberedChoicesStayFixedAcrossSearchAndModes() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(12))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map { ($0.element.hexcode, 100 - $0.offset) }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            let choices = browser.quickSuggestions.map(\.hexcode)
            #expect(choices == Array(sample.prefix(EmojiBrowserViewModel.numberSlotCount)).map(\.hexcode))
            browser.setQuery("heart")
            browser.selectMode(.all)
            browser.selectMode(.recent)
            #expect(browser.quickSuggestions.map(\.hexcode) == choices)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "mojito.tests.personal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    private func model(_ defaults: UserDefaults) -> EmojiBrowserViewModel {
        EmojiBrowserViewModel(database: .shared, quickAccess: QuickAccessStore(defaults: defaults), defaults: defaults)
    }
    @Test func contextSuggestionsUseExactLocalEmojiKeywords() {
        withDefaults { defaults in
            defaults.set(["1F602": 2], forKey: PrefsKey.usageCounts)
            let browser = EmojiBrowserViewModel(
                database: .shared,
                quickAccess: QuickAccessStore(defaults: defaults),
                defaults: defaults,
                contextText: "That was hilarious, laughing so hard"
            )
            #expect(browser.mode == .suggested)
            #expect(browser.current.first?.hexcode == "1F602")
            #expect(browser.availableModes.first == .suggested)
        }
    }
    @Test func numberedPreferenceIsReadWithoutBeingMutatedByBrowserModel() {
        withDefaults { defaults in
            let saved = ["1F680", "1F602"]
            defaults.set(saved, forKey: EmojiBrowserViewModel.numberedEmojiKey)
            let browser = model(defaults)
            #expect(browser.quickSuggestions.prefix(2).map(\.hexcode) == saved)
            #expect(defaults.stringArray(forKey: EmojiBrowserViewModel.numberedEmojiKey) == saved)
        }
    }
    @Test func wholeHistoryIsVisibleWithoutUnusedCatalogue() throws {
        try withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.filter { $0.group >= 0 }.prefix(49))
            #expect(sample.count == 49)
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map { ($0.element.hexcode, 49 - $0.offset) }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            #expect(browser.mode == .mostUsed)
            #expect(browser.current.map(\.hexcode) == sample.map(\.hexcode))
            var visible = Set<String>()
            for page in 0..<browser.shortcutPageCount {
                if page > 0 { browser.changeShortcutPage(by: 1) }
                visible.formUnion(browser.shortcutItems.map { $0.emoji.hexcode })
            }
            #expect(visible == Set(sample.map(\.hexcode)))
        }
    }
    @Test func recentsAreIndependentFromFrequencyAndSurviveReopen() {
        withDefaults { defaults in
            defaults.set(["1F602": 500, "1F680": 1], forKey: PrefsKey.usageCounts)
            EmojiRecents.record("1F602", defaults: defaults)
            EmojiRecents.record("1F680", defaults: defaults)
            EmojiRecents.record("1F602", defaults: defaults)
            EmojiRecents.record("1F680", defaults: defaults)
            let browser = model(defaults)
            #expect(browser.current.first?.hexcode == "1F602")
            browser.selectMode(.recent)
            #expect(browser.current.map(\.hexcode) == ["1F680", "1F602"])
            #expect(defaults.stringArray(forKey: PrefsKey.recentEmoji) == ["1F680", "1F602"])
        }
    }
    @Test func searchIsGlobalAndClearingRestoresPersonalMode() {
        withDefaults { defaults in
            defaults.set(["1F602": 5], forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            browser.hoverIndex = 0
            browser.setQuery("rocket")
            #expect(browser.hoverIndex == nil)
            #expect(browser.current.contains { $0.hexcode == "1F680" })
            browser.setQuery("")
            #expect(browser.current.map(\.hexcode) == ["1F602"])
            browser.setQuery("zzqxzzqxzzqx")
            #expect(browser.current.isEmpty)
            #expect(browser.selectedEmoji == nil)
            browser.selectMode(.all)
            #expect(browser.query.isEmpty)
            #expect(browser.current.count > 1000)
        }
    }
    @Test func allCategoryIndicesAndNavigationMatchVisibleCells() {
        withDefaults { defaults in
            defaults.set(["1F602": 5], forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            browser.selectMode(.all)
            for section in browser.sections {
                browser.selectCategory(section.category)
                #expect(browser.selectedEmoji?.hexcode == section.cells.first?.emoji.hexcode)
                for item in section.cells {
                    #expect(browser.current[item.id].hexcode == item.emoji.hexcode)
                }
            }
        }
    }
    @Test func letterKeysReadAlphabeticallyUnderOneRowOfNumbers() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(12))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            #expect(browser.pickerSlots.prefix(EmojiBrowserViewModel.numberSlotCount).map(\.shortcut) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
            let letters = browser.pickerSlots.dropFirst(EmojiBrowserViewModel.numberSlotCount).compactMap { $0.shortcut }
            #expect(letters == letters.sorted())
            #expect(!letters.isEmpty)
            #expect(browser.pickerSlots.count >= EmojiBrowserViewModel.minimumShortcutSlots)
            #expect(browser.pickerSlots.dropFirst(EmojiBrowserViewModel.numberSlotCount + letters.count).contains { $0.shortcut == nil && $0.emoji != nil })
        }
    }

    @Test func pickerFillsInEmojiThatHaveNoKey() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            let shown = Set(browser.pickerSlots.compactMap { $0.emoji?.hexcode })
            #expect(shown.isSuperset(of: Set(sample.map(\.hexcode))))
            let letters = browser.pickerSlots.compactMap(\.shortcut).filter { $0.first?.isLetter == true }
            #expect(Set(letters).count == letters.count)
            #expect(browser.pickerSlots.contains { $0.emoji != nil && $0.shortcut == nil })
        }
    }

    @Test func draggingOntoAnUnassignedEmojiClearsTheNumber() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            let number = browser.pickerSlots.first { $0.shortcut == "1" }?.emoji
            let unassigned = browser.pickerSlots.first { $0.shortcut == nil }?.emoji
            let kept = browser.pickerSlots.prefix(EmojiBrowserViewModel.numberSlotCount).dropFirst().compactMap { slot -> (String, String)? in
                guard let shortcut = slot.shortcut, let emoji = slot.emoji else { return nil }
                return (shortcut, emoji.hexcode)
            }
            guard let number, let unassigned else { return }
            browser.dropShortcut(from: number.hexcode, onto: unassigned.hexcode)
            #expect(browser.emojiForShortcut("1") == nil)
            #expect(browser.pickerSlots.first { $0.shortcut == "1" }?.emoji == nil)
            #expect(browser.pickerSlots.contains { $0.emoji?.hexcode == number.hexcode && $0.shortcut == nil })
            for (shortcut, hex) in kept {
                #expect(browser.pickerSlots.first { $0.shortcut == shortcut }?.emoji?.hexcode == hex)
            }
            let reopened = model(defaults)
            #expect(reopened.emojiForShortcut("1") == nil)
            #expect(reopened.pickerSlots.first { $0.shortcut == "1" }?.emoji == nil)
            for (shortcut, hex) in kept {
                #expect(reopened.pickerSlots.first { $0.shortcut == shortcut }?.emoji?.hexcode == hex)
            }
        }
    }

    @Test func droppingInEmptySpaceClearsAndDroppingOnTheSameCellCancels() {
        let flag = "1F1EE-1F1F3"
        let frames: [String: CGRect] = [
            flag: CGRect(x: 200, y: 160, width: 40, height: 40),
            "1F602": CGRect(x: 0, y: 0, width: 40, height: 40),
            "number-0": CGRect(x: 40, y: 0, width: 40, height: 40)
        ]
        #expect(ShortcutDrag.resolve(point: CGPoint(x: 220, y: 420), sourceHex: flag, frames: frames) == .unassign)
        #expect(ShortcutDrag.resolve(point: CGPoint(x: 210, y: 180), sourceHex: flag, frames: frames) == .cancel)
        #expect(ShortcutDrag.resolve(point: CGPoint(x: 16, y: 16), sourceHex: flag, frames: frames) == .emoji("1F602"))
        #expect(ShortcutDrag.resolve(point: CGPoint(x: 55, y: 16), sourceHex: flag, frames: frames) == .number(9))
    }

    @Test func clearingALetterLeavesThatSlotEmptyAndKeepsTheOthers() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            let letters = browser.pickerSlots.dropFirst(EmojiBrowserViewModel.numberSlotCount).prefix(26)
            #expect(letters.map { $0.shortcut } == EmojiBrowserViewModel.letterKeys.map { String($0) })
            guard let cleared = letters.first(where: { $0.emoji != nil }),
                  let letter = cleared.shortcut?.first,
                  let hex = cleared.emoji?.hexcode,
                  let unassigned = browser.pickerSlots.first(where: { $0.shortcut == nil })?.emoji else { return }
            let kept = letters.compactMap { slot -> (Character, String)? in
                guard let key = slot.shortcut?.first, key != letter, let emoji = slot.emoji else { return nil }
                return (key, emoji.hexcode)
            }
            browser.dropShortcut(from: hex, onto: unassigned.hexcode)
            #expect(browser.pickerSlots.first { $0.shortcut == String(letter) }?.emoji == nil)
            for (key, value) in kept {
                #expect(browser.emojiForShortcut(key)?.hexcode == value)
            }
            let reopened = model(defaults)
            #expect(reopened.pickerSlots.first { $0.shortcut == String(letter) }?.emoji == nil)
            for (key, value) in kept {
                #expect(reopened.emojiForShortcut(key)?.hexcode == value)
            }
            reopened.dropShortcut(from: unassigned.hexcode, ontoEmptyLetter: letter)
            #expect(reopened.emojiForShortcut(letter)?.hexcode == unassigned.hexcode)
        }
    }

    @Test func draggingOntoAKeyedEmojiTakesThatKey() {
        withDefaults { defaults in
            let sample = Array(EmojiDatabase.shared.all.prefix(40))
            defaults.set(Dictionary(uniqueKeysWithValues: sample.enumerated().map {
                ($0.element.hexcode, 100 - $0.offset)
            }), forKey: PrefsKey.usageCounts)
            let browser = model(defaults)
            guard let letterSlot = browser.pickerSlots.first(where: { $0.shortcut?.first?.isLetter == true }),
                  let letter = letterSlot.shortcut?.first,
                  let target = letterSlot.emoji,
                  let source = browser.pickerSlots.first(where: { $0.shortcut == nil })?.emoji else { return }
            browser.dropShortcut(from: source.hexcode, onto: target.hexcode)
            #expect(browser.emojiForShortcut(letter)?.hexcode == source.hexcode)
            #expect(browser.emojiForShortcut(letter)?.hexcode == model(defaults).emojiForShortcut(letter)?.hexcode)
        }
    }

    @Test func freshInstallOpensCatalogueAndRecentStaysEmpty() {
        withDefaults { defaults in
            let browser = model(defaults)
            #expect(browser.mode == .all)
            #expect(!browser.shortcutItems.isEmpty)
            browser.selectMode(.recent)
            #expect(browser.current.isEmpty)
            browser.move(.down)
            #expect(browser.selectedEmoji == nil)
            browser.selectMode(.all)
            #expect(!browser.current.isEmpty)
        }
    }
    @Test func modeChangeClearsTheEngineQueryBeforeFurtherTyping() {
        withDefaults { defaults in
            let browser = model(defaults)
            var machine = TriggerStateMachine()
            machine.enterBrowsing(query: "heart")
            browser.setQuery("heart")
            browser.onModeChange = { machine.setBrowsingQuery(""); machine.setBrowserSearchInputActive(false) }
            browser.selectMode(.recent)
            let output = machine.handle(.nameChar("r"))
            #expect(output.action == .pickBrowserShortcut(key: "r"))
            #expect(browser.query.isEmpty)
        }
    }
    @Test func changingModesResetsDeepSelectionAndHover() {
        withDefaults { defaults in
            defaults.set(["1F602": 5, "1F680": 2], forKey: PrefsKey.usageCounts)
            defaults.set(["1F680", "1F602"], forKey: PrefsKey.recentEmoji)
            let browser = model(defaults)
            browser.selectMode(.all)
            browser.selectedIndex = 900
            browser.hoverIndex = 901
            browser.selectMode(.recent)
            #expect(browser.hoverIndex == nil)
            #expect(browser.selectedIndex == 0)
            #expect(browser.selectedEmoji?.hexcode == "1F602")
            browser.move(.right)
            #expect(browser.selectedEmoji?.hexcode == "1F680")
            browser.setQuery("heart")
            browser.selectMode(.recent)
            #expect(browser.query.isEmpty)
            #expect(browser.current.map(\.hexcode) == ["1F680", "1F602"])
        }
    }
    @Test func futureUsageChangesTheRanking() {
        withDefaults { defaults in
            defaults.set(["1F602": 5, "1F680": 1], forKey: PrefsKey.usageCounts)
            #expect(model(defaults).current.first?.hexcode == "1F602")
            defaults.set(["1F602": 5, "1F680": 6], forKey: PrefsKey.usageCounts)
            #expect(model(defaults).current.first?.hexcode == "1F680")
        }
    }
}
