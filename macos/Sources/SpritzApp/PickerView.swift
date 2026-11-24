import AppKit
import SwiftUI

private extension Color {
    static let pickerSelection = Color.primary.opacity(0.16)
}

struct PickerRootView: View {
    @ObservedObject var bridge: SpritzBridge
    var editableSearch: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if let picker = bridge.snapshot.picker {
                InlineEmojiBrowserView(
                    picker: picker,
                    editableSearch: editableSearch,
                    onBeginSearch: { bridge.beginSearch() },
                    onQueryChange: { bridge.setQuery($0) },
                    onSelectMode: { bridge.selectMode($0) },
                    onSelectCategory: { bridge.selectCategory($0) },
                    onPickHex: { hex, keepOpen in bridge.pickHex(hex, keepOpen: keepOpen) },
                    onDropResolved: { hex, pt, frames in
                        bridge.resolveDrag(sourceHex: hex, point: pt, frames: frames)
                    }
                )
            }
            DictationSwapStrip(
                dictation: bridge.snapshot.dictation,
                onAnalyse: { bridge.analyseFocusedText() },
                onSelectChoice: { bridge.selectDictationChoice($0) },
                onChoose: { idx in bridge.chooseDictationChoice(idx, keepOpen: true) }
            )
        }
        .frame(
            width: PickerLayout.browserWidth,
            height: PickerLayout.browserHeight + CGFloat(bridge.snapshot.dictation.stripHeight)
        )
    }
}

private struct TooltipData: Sendable {
    let text: String
    let anchor: Anchor<CGRect>
}

private struct TooltipAnchorKey: PreferenceKey {
    static let defaultValue: TooltipData? = nil
    static func reduce(value: inout TooltipData?, nextValue: () -> TooltipData?) {
        value = nextValue() ?? value
    }
}

private final class SlotFrames {
    var values: [String: CGRect] = [:]
}

private struct SlotFrameReporter: View {
    let id: String
    let frames: SlotFrames
    let spaceName: String

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { frames.values[id] = geo.frame(in: .named(spaceName)) }
                .onDisappear { frames.values.removeValue(forKey: id) }
                .onChange(of: geo.frame(in: .named(spaceName))) { _, frame in
                    frames.values[id] = frame
                }
        }
    }
}

private struct GlyphTooltip: View {
    let name: String

    var body: some View {
        Text(name)
            .foregroundStyle(.primary)
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

struct InlineEmojiBrowserView: View {
    let picker: PickerViewDTO
    let editableSearch: Bool
    let onBeginSearch: () -> Void
    let onQueryChange: (String) -> Void
    let onSelectMode: (String) -> Void
    let onSelectCategory: (String) -> Void
    let onPickHex: (String, Bool) -> Void
    let onDropResolved: (String, CGPoint, [String: CGRect]) -> Void

    @State private var tooltipSize: CGSize = .zero
    @State private var typedQuery = ""
    @State private var slotFrames = SlotFrames()
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let gridSpace = "spritzPickerGrid"
    private static let searchRowHeight: CGFloat = 48
    private static let cellHeight: CGFloat = 40
    private static let rowSpacing: CGFloat = 3
    private static let tabBarHeight: CGFloat = 40

    private var shortcutColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 32), spacing: PickerLayout.gridSpacing), count: 10)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 36), spacing: PickerLayout.gridSpacing), count: 7)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            modeBar
            hairline
            if !editableSearch && !picker.searchInputActive {
                shortcutGrid
            } else {
                browseGrid
            }
        }
        .frame(width: PickerLayout.browserWidth, height: PickerLayout.browserHeight)
        .onChange(of: picker.query) { _, v in
            if editableSearch && typedQuery != v { typedQuery = v }
        }
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
                    GlyphTooltip(name: data.text)
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

    private var searchHeader: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.trailing, 3)
            if editableSearch {
                TextField("Search emoji", text: $typedQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: typedQuery) { _, v in onQueryChange(v) }
            } else {
                ZStack(alignment: .leading) {
                    if picker.query.isEmpty {
                        Text("Search emoji").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 0) {
                        Text(picker.query).foregroundStyle(.primary)
                        if picker.searchInputActive { blinkingCaret }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, 10)
        .frame(height: Self.searchRowHeight)
        .background(colorScheme == .light ? Color.white.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if editableSearch { searchFocused = true } else { onBeginSearch() }
        }
    }

    private var blinkingCaret: some View {
        TimelineView(.periodic(from: .now, by: 0.6)) { context in
            let on = Int(context.date.timeIntervalSince1970 / 0.6) % 2 == 0
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2, height: 17)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 2)
    }

    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach(picker.availableModes, id: \.self) { m in
                Button { onSelectMode(m) } label: {
                    Text(Self.modeTitle(m))
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 25)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(picker.mode == m ? Color.pickerSelection : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 10)
        .frame(height: 34)
    }

    private static func modeTitle(_ raw: String) -> String {
        switch raw {
        case "suggested": return "Suggested"
        case "mostUsed": return "Most used"
        case "recent": return "Recent"
        case "all": return "All"
        default: return raw
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private var shortcutGrid: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: shortcutColumns, spacing: Self.rowSpacing) {
                        ForEach(Array(picker.slots.enumerated()), id: \.element.id) { index, slot in
                            if let hex = slot.hex, let glyph = slot.glyph {
                                ShortcutDragCell(
                                    hex: hex,
                                    glyph: glyph,
                                    label: slot.label ?? "",
                                    shortcode: slot.shortcode ?? "",
                                    shortcut: slot.shortcut,
                                    isSelected: index == picker.shortcutSelectedIndex,
                                    cellHeight: Self.cellHeight,
                                    spaceName: Self.gridSpace,
                                    frames: slotFrames,
                                    onPick: { onPickHex(hex, NSEvent.modifierFlags.contains(.shift)) },
                                    onDropEnd: { point in
                                        onDropResolved(hex, point, slotFrames.values)
                                    }
                                )
                                .id(slot.id)
                            } else {
                                emptySlotCell(
                                    id: slot.id,
                                    label: slot.shortcut ?? "",
                                    selected: index == picker.shortcutSelectedIndex
                                )
                                .background(SlotFrameReporter(id: slot.id, frames: slotFrames, spaceName: Self.gridSpace))
                                .id(slot.id)
                            }
                        }
                    }
                    .padding(.horizontal, PickerLayout.gridInset)
                    .padding(.top, 2)
                }
                .scrollClipDisabled(true)
                .coordinateSpace(name: Self.gridSpace)
                .onChange(of: picker.scrollSlotSeq) { _, _ in
                    if let target = picker.scrollTargetSlot {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
            if picker.mode == "all" { categoryBar }
        }
    }

    private func emptySlotCell(id: String, label: String, selected: Bool) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(selected ? 0.35 : 0.12),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            )
            .overlay(alignment: .topLeading) {
                Text(verbatim: label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
            }
            .accessibilityLabel("\(label), empty")
    }

    private var browseGrid: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if picker.gridItems.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                            Text(picker.isSearching ? "No emoji matching \"\(picker.query)\"" : "No history yet")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 56)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: Self.rowSpacing) {
                            ForEach(Array(picker.gridItems.enumerated()), id: \.offset) { idx, item in
                                EmojiGlyphCell(
                                    glyph: item.glyph,
                                    label: item.label,
                                    shortcode: item.shortcode,
                                    shortcut: nil,
                                    isSelected: idx == picker.selectedIndex,
                                    cellHeight: Self.cellHeight,
                                    tooltipEnabled: true,
                                    onPick: { onPickHex(item.hex, NSEvent.modifierFlags.contains(.shift)) }
                                )
                                .id(idx)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
                .onChange(of: picker.scrollGridSeq) { _, _ in
                    if let target = picker.scrollTargetGrid {
                        proxy.scrollTo(target, anchor: target == 0 ? .top : nil)
                    }
                }
            }
            if picker.mode == "all" { categoryBar }
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 1) {
            ForEach(picker.sections) { sec in
                let active = !picker.isSearching && picker.activeCategory == sec.category
                Button { onSelectCategory(sec.category) } label: {
                    Image(systemName: sec.tabSymbol)
                        .font(.system(size: 13))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 28)
                        .background(Circle().fill(active ? Color.pickerSelection : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sec.title)
                .accessibilityLabel(sec.title)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: Self.tabBarHeight)
        .background(
            colorScheme == .dark
                ? Color(red: 0.13, green: 0.13, blue: 0.14)
                : Color(red: 0.96, green: 0.96, blue: 0.97)
        )
        .overlay(alignment: .top) { hairline }
    }
}

private struct ShortcutDragCell: View {
    let hex: String
    let glyph: String
    let label: String
    let shortcode: String
    let shortcut: String?
    let isSelected: Bool
    let cellHeight: CGFloat
    let spaceName: String
    let frames: SlotFrames
    let onPick: () -> Void
    let onDropEnd: (CGPoint) -> Void

    @State private var offset: CGSize = .zero
    @State private var dragging = false
    @State private var origin: CGRect = .zero

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(dragging ? 0.18 : 0),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
            }
            .overlay {
                EmojiGlyphCell(
                    glyph: glyph,
                    label: label,
                    shortcode: shortcode,
                    shortcut: shortcut,
                    isSelected: isSelected,
                    cellHeight: cellHeight,
                    tooltipEnabled: !dragging,
                    onPick: onPick
                )
                .opacity(dragging ? 0 : 1)
            }
            .overlay {
                if dragging {
                    EmojiGlyphCell(
                        glyph: glyph,
                        label: label,
                        shortcode: shortcode,
                        shortcut: shortcut,
                        isSelected: false,
                        cellHeight: cellHeight,
                        tooltipEnabled: false,
                        onPick: {}
                    )
                    .offset(offset)
                    .allowsHitTesting(false)
                }
            }
            .background(SlotFrameReporter(id: hex, frames: frames, spaceName: spaceName))
            .zIndex(dragging ? 2 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named(spaceName))
                    .onChanged { value in
                        if !dragging {
                            origin = frames.values[hex] ?? .zero
                            dragging = true
                        }
                        offset = value.translation
                    }
                    .onEnded { value in
                        let point = CGPoint(x: origin.midX + value.translation.width, y: origin.midY + value.translation.height)
                        offset = .zero
                        dragging = false
                        guard origin.width > 0 else { return }
                        onDropEnd(point)
                    }
            )
    }
}

private struct EmojiGlyphCell: View {
    let glyph: String
    let label: String
    let shortcode: String
    let shortcut: String?
    let isSelected: Bool
    let cellHeight: CGFloat
    let tooltipEnabled: Bool
    let onPick: () -> Void

    @State private var hovered = false
    @State private var showTooltip = false
    @State private var tooltipWork: DispatchWorkItem?

    var body: some View {
        let highlighted = isSelected || hovered
        Text(glyph)
            .font(.system(size: 25))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.pickerSelection : .clear)
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
            .accessibilityLabel(shortcut.map { "\($0), \(label)" } ?? label)
            .anchorPreference(key: TooltipAnchorKey.self, value: .bounds) { anchor in
                showTooltip && !shortcode.isEmpty ? TooltipData(text: ":\(shortcode):", anchor: anchor) : nil
            }
            .onTapGesture { onPick() }
            .onHover { hovering in
                tooltipWork?.cancel()
                hovered = hovering
                guard tooltipEnabled else { showTooltip = false; return }
                if hovering {
                    let w = DispatchWorkItem { showTooltip = true }
                    tooltipWork = w
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
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

struct DictationSwapStrip: View {
    let dictation: DictationDTO
    let onAnalyse: () -> Void
    let onSelectChoice: (Int) -> Void
    let onChoose: (Int) -> Void

    var body: some View {
        if dictation.hasStripContent {
            VStack(spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    if dictation.choices.isEmpty {
                        Text("Text alternatives")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Analyse text", action: onAnalyse)
                    } else {
                        let selectionBinding = Binding<Int>(
                            get: { min(dictation.selected, max(0, dictation.choices.count - 1)) },
                            set: { onSelectChoice($0) }
                        )
                        Picker("Text", selection: selectionBinding) {
                            ForEach(Array(dictation.choices.indices), id: \.self) { i in
                                Text(dictation.labels.indices.contains(i) ? dictation.labels[i] : "Option").tag(i)
                            }
                        }
                        .labelsHidden()
                        Text(dictation.textPreviewActive ? "⇧⇥ / ⇥ · ↵" : "⇧⇥ / ⇥")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if dictation.busy { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                        Button(dictation.copyOnly ? "Copy" : "Use") {
                            onChoose(min(dictation.selected, dictation.choices.count - 1))
                        }
                    }
                }
                .padding(.horizontal, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            dictation.choices.indices.contains(dictation.selected)
                                ? dictation.choices[dictation.selected]
                                : "Dictate, then review the complete passage here."
                        )
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        if !dictation.reviewNotes.isEmpty, dictation.selected >= dictation.choices.count - 1 {
                            Divider()
                            Text(dictation.reviewNotes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                }
                if !dictation.status.isEmpty {
                    Text(dictation.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 10)
            .frame(height: dictation.stripHeight)
        } else {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Text("Text alternatives")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Analyse text", action: onAnalyse)
                        .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
            }
            .frame(height: dictation.stripHeight)
        }
    }
}
