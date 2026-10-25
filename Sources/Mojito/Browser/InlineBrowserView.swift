import Combine
import SwiftUI

/// The full-library grid, shown by *growing the picker panel* (not a separate
/// window). Driven by the trigger state machine through `EmojiBrowserViewModel`
/// — the panel stays non-key so the focused app keeps its insertion point and
/// picks are typed straight in.
///
/// One **continuous scrolling list** (like the macOS system emoji picker): every
/// category is a section in a single scroll view. The tab bar jumps to a section
/// and tracks whichever section you've scrolled to. The outer container is a
/// plain `VStack` (not lazy) so each section sits at an exact offset — that's
/// what makes `scrollTo` pixel-accurate with no drift — while each section's
/// `LazyVGrid` still renders its cells lazily, so opening stays cheap.
///
/// The panel is non-key, so native `.help` tooltips don't fire; glyph names use
/// a custom root overlay.
struct InlineBrowserView: View {
    @ObservedObject var browser: EmojiBrowserViewModel
    let onPick: (Emoji) -> Void
    let onCategory: (EmojiCategory) -> Void
    /// In the live panel the search row is display-only (the event tap feeds it).
    /// Hosted in a key window (the Settings slot picker), it becomes a real
    /// editable `TextField`.
    var editableSearch: Bool = false

    @State private var tooltipSize: CGSize = .zero
    @State private var typedQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let scrollSpace = "browserScroll"
    fileprivate static let pickerGridSpace = "pickerGrid"
    fileprivate static let cellHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 3
    /// Tab bar height (icon row). The grid scrolls under it, so the scroll
    /// content is inset by this much at the bottom.
    private static let tabBarHeight: CGFloat = 40
    private static let searchRowHeight: CGFloat = 48
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 36), spacing: 3),
        count: EmojiBrowserViewModel.columns
    )

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            modeBar
            hairline
            if !editableSearch && !browser.searchInputActive {
                shortcutGrid
            } else {
                grid
            }
        }
        .frame(width: BrowserLayout.width, height: BrowserLayout.height)
        .onChange(of: browser.query) { _, value in
            if editableSearch && typedQuery != value { typedQuery = value }
        }
        // Tooltip drawn at the root so it can sit above the top row without
        // being clipped by the scroll view. Clamps to the panel using the
        // bubble's measured width and flips below near the search row, so long
        // shortcodes never overflow an edge.
        .overlayPreferenceValue(TooltipAnchorKey.self) { data in
            GeometryReader { proxy in
                if let data {
                    let cell = proxy[data.anchor]
                    let margin: CGFloat = 6
                    let halfW = tooltipSize.width / 2
                    let x = min(max(cell.midX, halfW + margin), proxy.size.width - halfW - margin)
                    let fitsAbove = cell.minY - margin - tooltipSize.height >= Self.searchRowHeight + 34 + 4
                    let y = fitsAbove
                        ? cell.minY - margin - tooltipSize.height / 2
                        : cell.maxY + margin + tooltipSize.height / 2
                    EmojiTooltip(name: data.text)
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { tooltipSize = g.size }
                                .onChange(of: g.size) { _, s in tooltipSize = s }
                        })
                        .position(x: x, y: y)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // Plain buttons share the existing non-key panel's click behaviour;
    // the familiar segmented shape does not require moving text focus.
    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach(browser.availableModes) { mode in
                Button { browser.selectMode(mode) } label: {
                    Text(mode.title)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(browser.mode == mode ? Color.pickerSelection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(browser.mode == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    // MARK: Search row

    private var searchHeader: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.trailing, 3)
            if editableSearch {
                TextField("Search emoji", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onChange(of: typedQuery) { _, value in browser.setQuery(value) }
            } else {
                // The placeholder sits under the caret, as in a native field,
                // so the caret marks where typing starts.
                ZStack(alignment: .leading) {
                    if browser.query.isEmpty {
                        Text("Search emoji").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 0) {
                        Text(browser.query).foregroundStyle(.primary)
                        if browser.searchInputActive { caret }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .modifier(SearchFieldChrome())
        .padding(.horizontal, 10)
        .frame(height: Self.searchRowHeight)
        .background(searchRowLift)
        .contentShape(Rectangle())
        .onTapGesture {
            if editableSearch { searchFieldFocused = true }
            else { browser.beginSearch() }
        }
    }

    /// The system picker's search header sits a step lighter than its grid.
    private var searchRowLift: Color {
        colorScheme == .light ? Color.white.opacity(0.2) : .clear
    }

    /// Blinks from the moment the browser opens: keystrokes are routed to the
    /// query for as long as it's on screen, so the row is live before any click.
    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let on = Int(context.date.timeIntervalSince1970 / 0.6) % 2 == 0
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2, height: 17)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 2)
    }

    // MARK: Grid (continuous list / search results)

    /// One `LazyVGrid` for the whole library (sectioned) or the flat search
    /// results. A single lazy container recycles cells correctly — splitting it
    /// per section is what let one section's glyphs ghost over another's. The
    /// tab bar insets the bottom safe area: content scrolls *under* it (so emoji
    /// blur through it) while `scrollTo` keeps keyboard-selected cells above it
    /// instead of leaving them hidden behind it.
    private var shortcutGrid: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 32), spacing: BrowserLayout.gridSpacing), count: EmojiBrowserViewModel.shortcutColumns), spacing: Self.rowSpacing) {
                        ForEach(Array(browser.pickerSlots.enumerated()), id: \.element.id) { index, slot in
                            if let emoji = slot.emoji {
                                ShortcutDragCell(emoji: emoji, index: index,
                                                 isKeyboardSelected: index == browser.shortcutSelectedIndex,
                                                 shortcut: slot.shortcut, frames: slotFrames,
                                                 onPick: onPick) { point in
                                    finishShortcutDrag(from: emoji.hexcode, at: point)
                                }
                            } else if let shortcut = slot.shortcut {
                                emptyNumberSlot(id: slot.id, label: shortcut, selected: index == browser.shortcutSelectedIndex)
                                    .background(SlotFrameReporter(id: slot.id, frames: slotFrames))
                            }
                        }
                    }
                    .padding(.horizontal, BrowserLayout.gridInset)
                    .padding(.top, 2)
                }
                .scrollClipDisabled(true)
                .coordinateSpace(name: Self.pickerGridSpace)
                .onChange(of: browser.keyboardScrollIndex) { _, index in
                    guard let index, browser.pickerSlots.indices.contains(index) else { return }
                    proxy.scrollTo(browser.pickerSlots[index].id)
                    browser.keyboardScrollIndex = nil
                }
            }
            if browser.mode == .all { categoryBar }
        }
    }

    /// Layout frames of the shortcut cells, written by the cells and read when
    /// a drag ends. Not observed, so updating it does not rebuild the scroller.
    @State private var slotFrames = SlotFrames()

    private func finishShortcutDrag(from hex: String, at point: CGPoint) {
        switch ShortcutDrag.resolve(point: point, sourceHex: hex, frames: slotFrames.values) {
        case .cancel:
            return
        case .unassign:
            browser.dropShortcutOnUnassigned(from: hex)
        case .number(let index):
            browser.dropShortcut(from: hex, ontoEmptyNumber: index)
        case .letter(let letter):
            browser.dropShortcut(from: hex, ontoEmptyLetter: letter)
        case .emoji(let target):
            browser.dropShortcut(from: hex, onto: target)
        }
    }

    private func emptyNumberSlot(id: String, label: String, selected: Bool) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(selected ? 0.35 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            )
            .overlay(alignment: .topLeading) {
                Text(verbatim: label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .accessibilityLabel("\(label), empty")
            .accessibilityIdentifier(id)
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if browser.current.isEmpty {
                    emptyResults
                } else {
                    LazyVGrid(columns: columns, spacing: Self.rowSpacing) {
                        if !browser.showsCategories {
                            // Positional index is the identity here — it's what
                            // `scrollTo` (reset-to-top, keyboard nav) addresses.
                            ForEach(Array(browser.current.enumerated()), id: \.offset) { index, emoji in
                                cell(emoji, index: index)
                            }
                        } else {
                            ForEach(browser.sections) { section in
                                Section {
                                    ForEach(section.cells) { item in
                                        cell(item.emoji, index: item.id)
                                    }
                                } header: {
                                    sectionHeader(section.category)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    // Search and library both index cells from 0; give the two
                    // modes distinct grid identity so the library→search switch
                    // rebuilds instead of reusing the most-used row's cells for
                    // the first search render (the "garbage first search" bug).
                    .id("\(browser.mode.rawValue)-\(browser.isSearching)")
                }
            }
            .contentMargins(.top, 2, for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if browser.mode == .all { categoryBar }
            }
            .coordinateSpace(name: Self.scrollSpace)
            // Active tab follows the scroll position.
            .onPreferenceChange(SectionOffsetKey.self) { offsets in
                browser.updateActiveCategory(from: offsets)
            }
            // Keyboard nav / reset-to-top scroll a single cell into view.
            .onChange(of: browser.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: target == 0 ? .top : nil)
                DispatchQueue.main.async { browser.scrollTarget = nil }
            }
            // Tab tap jumps to a section header.
            .onChange(of: browser.categoryTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                DispatchQueue.main.async { browser.categoryTarget = nil }
            }
        }
    }

    private func sectionHeader(_ category: EmojiCategory) -> some View {
        Text(category.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .id(category)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SectionOffsetKey.self,
                        value: [category: geo.frame(in: .named(Self.scrollSpace)).minY]
                    )
                }
            )
    }

    private func cell(_ emoji: Emoji, index: Int) -> some View {
        BrowserCell(
            emoji: emoji,
            index: index,
            isKeyboardSelected: index == browser.selectedIndex,
            cellHeight: Self.cellHeight,
            onPick: onPick,
            onHoverChanged: { browser.hoverIndex = $0 }
        )
    }

    private var emptyResults: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(browser.isSearching ? String(localized: "No emoji matching “\(browser.query)”") : "No history yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: Tab bar

    private var categoryBar: some View {
        CategoryTabBar(
            categories: browser.visibleCategories,
            isSearching: browser.isSearching,
            activeCategoryPublisher: browser.activeCategoryPublisher,
            initialActiveCategory: browser.activeCategory,
            tabBarHeight: Self.tabBarHeight,
            onCategory: onCategory
        )
        .modifier(TabBarBackground())
        .overlay(alignment: .top) { hairline }
    }
}

/// Holds layout frames without publishing, so a drag can hit-test a drop slot
/// without rebuilding the scroll view on every pointer move.
final class SlotFrames {
    var values: [String: CGRect] = [:]
}

private struct SlotFrameReporter: View {
    let id: String
    let frames: SlotFrames

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frames.values[id] = geo.frame(in: .named(InlineBrowserView.pickerGridSpace)) }
                .onChange(of: geo.frame(in: .named(InlineBrowserView.pickerGridSpace))) { _, frame in
                    frames.values[id] = frame
                }
        }
    }
}

/// Where a shortcut drag was released. A miss is the empty area, which clears
/// the key. Landing back on the same cell puts the icon back.
enum ShortcutDrag {
    enum Action: Equatable {
        case cancel
        case unassign
        case number(Int)
        case letter(Character)
        case emoji(String)
    }

    static func resolve(point: CGPoint, sourceHex: String, frames: [String: CGRect]) -> Action {
        if let own = frames[sourceHex], own.contains(point) { return .cancel }
        let hits = frames.filter { $0.key != sourceHex && $0.value.insetBy(dx: -4, dy: -4).contains(point) }
        guard let target = hits.min(by: {
            hypot($0.value.midX - point.x, $0.value.midY - point.y)
                < hypot($1.value.midX - point.x, $1.value.midY - point.y)
        }) else { return .unassign }
        if target.key.hasPrefix("number-"),
           let label = target.key.split(separator: "-").last,
           let index = EmojiBrowserViewModel.numberKeys.firstIndex(of: Character(String(label))) {
            return .number(index)
        }
        if target.key.hasPrefix("letter-"),
           let label = target.key.split(separator: "-").last,
           label.count == 1, let letter = label.first {
            return .letter(letter)
        }
        return .emoji(target.key)
    }
}

/// Drags the whole cell with the pointer. The slot stays put as an empty
/// outline; the icon and its key move at full size. State stays on this cell
/// so the scrolling parent does not rebuild.
private struct ShortcutDragCell: View {
    let emoji: Emoji
    let index: Int
    let isKeyboardSelected: Bool
    let shortcut: String?
    let frames: SlotFrames
    let onPick: (Emoji) -> Void
    let onDragEnd: (CGPoint) -> Void

    @State private var offset: CGSize = .zero
    @State private var dragging = false
    @State private var origin: CGRect = .zero

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: InlineBrowserView.cellHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(dragging ? 0.18 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .overlay {
                cell(flying: false)
                    .opacity(dragging ? 0 : 1)
            }
            .overlay {
                if dragging {
                    cell(flying: true)
                        .offset(offset)
                        .allowsHitTesting(false)
                }
            }
            .background(SlotFrameReporter(id: emoji.hexcode, frames: frames))
            .zIndex(dragging ? 2 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(InlineBrowserView.pickerGridSpace))
                    .onChanged { value in
                        if !dragging {
                            origin = frames.values[emoji.hexcode] ?? .zero
                            dragging = true
                        }
                        offset = value.translation
                    }
                    .onEnded { value in
                        let point = CGPoint(x: origin.midX + value.translation.width,
                                            y: origin.midY + value.translation.height)
                        offset = .zero
                        dragging = false
                        guard origin.width > 0 else { return }
                        onDragEnd(point)
                    }
            )
    }

    private func cell(flying: Bool) -> some View {
        BrowserCell(emoji: emoji, index: index,
                    isKeyboardSelected: isKeyboardSelected && !flying,
                    cellHeight: InlineBrowserView.cellHeight,
                    shortcut: shortcut, onPick: onPick, onHoverChanged: { _ in },
                    tooltipEnabled: !dragging && !flying)
    }
}

/// One emoji cell, broken out so hover state is per-cell `@State` and a cell
/// scrolling under the cursor only invalidates itself — not the parent
/// `InlineBrowserView`, which would re-evaluate the `ScrollView` and reset the
/// scroll position on macOS 27 beta 1.
private struct BrowserCell: View {
    let emoji: Emoji
    let index: Int
    let isKeyboardSelected: Bool
    let cellHeight: CGFloat
    var shortcut: String? = nil
    let onPick: (Emoji) -> Void
    let onHoverChanged: (Int?) -> Void
    var tooltipEnabled: Bool = true

    @State private var hovered: Bool = false
    @State private var showTooltip: Bool = false
    @State private var tooltipWork: DispatchWorkItem?

    var body: some View {
        let glyph = emoji.tonedGlyph
        let highlighted = isKeyboardSelected || hovered
        Text(glyph)
            .font(.system(size: 25))  // match the pill's glyph size
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.pickerSelection : Color.clear)
            )
            .overlay(alignment: .topLeading) {
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
            .accessibilityLabel(Text(verbatim: shortcut.map { "\($0), \(emoji.label)" } ?? emoji.label))
            .anchorPreference(key: TooltipAnchorKey.self, value: .bounds) { anchor in
                showTooltip ? TooltipData(text: ":\(emoji.primaryShortcode):", anchor: anchor) : nil
            }
            .onTapGesture { onPick(emoji) }
            .onHover { hovering in
                tooltipWork?.cancel()
                hovered = hovering
                onHoverChanged(hovering ? index : nil)
                guard tooltipEnabled else { showTooltip = false; return }
                if hovering {
                    let work = DispatchWorkItem { showTooltip = true }
                    tooltipWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                } else {
                    showTooltip = false
                }
            }
            .onChange(of: tooltipEnabled) { _, enabled in
                if !enabled {
                    tooltipWork?.cancel()
                    showTooltip = false
                }
            }
    }
}

/// Tab bar pulled into its own view so the active-section highlight tracks the
/// scroll position through a local `@State` driven by a Combine publisher,
/// instead of through a `@Published` on `EmojiBrowserViewModel`. The point: a
/// scroll-driven activeCategory change must not invalidate the parent
/// `InlineBrowserView` body (and re-evaluate the `ScrollView`/`LazyVGrid`
/// mid-scroll, which on macOS 27 beta 1 snapped the scroll position back).
private struct CategoryTabBar: View {
    let categories: [EmojiCategory]
    let isSearching: Bool
    let activeCategoryPublisher: AnyPublisher<EmojiCategory, Never>
    let tabBarHeight: CGFloat
    let onCategory: (EmojiCategory) -> Void
    @State private var activeCategory: EmojiCategory

    init(
        categories: [EmojiCategory],
        isSearching: Bool,
        activeCategoryPublisher: AnyPublisher<EmojiCategory, Never>,
        initialActiveCategory: EmojiCategory,
        tabBarHeight: CGFloat,
        onCategory: @escaping (EmojiCategory) -> Void
    ) {
        self.categories = categories
        self.isSearching = isSearching
        self.activeCategoryPublisher = activeCategoryPublisher
        self.tabBarHeight = tabBarHeight
        self.onCategory = onCategory
        self._activeCategory = State(initialValue: initialActiveCategory)
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(categories) { category in
                let isActive = !isSearching && activeCategory == category
                Button {
                    onCategory(category)
                } label: {
                    Image(systemName: category.tabSymbol)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 28)
                        .background(
                            Circle()
                                .fill(isActive ? Color.pickerSelection : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(category.title)
            }
            Spacer(minLength: 0)
        }
        // With the bar 40pt tall, this centers the first tab 20pt in from the
        // bottom-left corner, so its circle is concentric with the panel's
        // 20pt corner radius.
        .padding(.horizontal, 5)
        .frame(height: tabBarHeight)
        .onReceive(activeCategoryPublisher) { activeCategory = $0 }
    }
}

/// Capsule search field, as in the system emoji picker. On Tahoe it's its
/// own glass, so it reads lighter than the header over dark backdrops and a
/// touch darker over light ones, like the system field.
private struct SearchFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Opaque enough to keep scrolling glyphs from competing with tab icons.
private struct TabBarBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background(colorScheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.14)
            : Color(red: 0.96, green: 0.96, blue: 0.97))
    }
}

/// Carries the hovered cell's bounds + name to the root tooltip overlay.
private struct TooltipData {
    let text: String
    let anchor: Anchor<CGRect>
}

private struct TooltipAnchorKey: PreferenceKey {
    static var defaultValue: TooltipData? = nil
    static func reduce(value: inout TooltipData?, nextValue: () -> TooltipData?) {
        value = nextValue() ?? value
    }
}

/// Each section header reports its top offset (in the scroll view's coordinate
/// space) so the view model can tell which section is currently at the top.
private struct SectionOffsetKey: PreferenceKey {
    static var defaultValue: [EmojiCategory: CGFloat] = [:]
    static func reduce(value: inout [EmojiCategory: CGFloat], nextValue: () -> [EmojiCategory: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

enum BrowserLayout {
    /// The 8-column panel was 352pt. Ten columns keep that cell width, so the
    /// number row is one line and the targets stay the same size.
    private static let eightColumnWidth: CGFloat = 352
    static let gridInset: CGFloat = 8
    static let gridSpacing: CGFloat = 3
    static let cellWidth: CGFloat = {
        let columns: CGFloat = 8
        let inner = eightColumnWidth - gridInset * 2
        return (inner - gridSpacing * (columns - 1)) / columns
    }()
    static var width: CGFloat {
        let columns = CGFloat(EmojiBrowserViewModel.shortcutColumns)
        return (gridInset * 2 + cellWidth * columns + gridSpacing * (columns - 1)).rounded()
    }
    static let height: CGFloat = {
        if #available(macOS 26.0, *) { return 420 }
        return 425
    }()
    /// The system emoji picker's radius.
    static let cornerRadius: CGFloat = 20
}
