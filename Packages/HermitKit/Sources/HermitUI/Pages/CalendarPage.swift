import SwiftUI

/// Calendar (Notion Calendar-style): Week (a day with a week strip on iPhone), Month and Board over one list
/// of tasks and events. Project colours and filter chips, Today and arrows, click an empty slot to add,
/// click an item to open it.
struct CalendarPage: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .week
    @State private var cursor = CalendarData.today
    @State private var filter: String?
    @State private var edit: CalItem?
    @State private var width: CGFloat = 1000
    @State private var step = 1
    private var store: CalendarStore { .shared }

    enum Mode: String, Hashable { case week, month, board }

    var body: some View {
        let compact = width < 700
        Page(title: "Calendar", tabs: [(0, "Calendar")], tab: .constant(0)) {
            if !compact { controls(compact) }
        } content: { _ in
            VStack(alignment: .leading, spacing: 16) {
                if compact { controls(compact) }
                chips
                if mode != .board { nav(compact) }
                Group {
                    switch mode {
                    case .week:
                        CalWeekView(days: days(compact), items: items, compact: compact, selected: cursor,
                                    onPick: { cursor = $0 }, onOpen: { edit = $0 })
                            .id("w\(key(compact))")
                    case .month:
                        CalMonthView(cursor: cursor, items: items, compact: compact,
                                     onDay: { cursor = $0; mode = .week }, onOpen: { edit = $0 })
                            .id("m\(CalendarData.format(cursor, "yyyyMM"))")
                    case .board:
                        CalBoard(items: items, compact: compact, onOpen: { edit = $0 })
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: CGFloat(step) * 24)), removal: .opacity))
            }
            .animation(.smooth(duration: 0.3), value: mode)
            .animation(.smooth(duration: 0.3), value: cursor)
            .animation(.snappy(duration: 0.25), value: filter)
        }
        .payWidth($width)
        .sheet(item: $edit) { CalItemSheet(item: $0) }
        .onAppear {
            if let r = model.tabRequest {
                if let m = Mode(rawValue: r) { mode = m } else if r == "day" { mode = .week }
                model.tabRequest = nil
            }
        }
    }

    private var items: [CalItem] { store.items.filter { filter == nil || $0.project == filter } }

    private func days(_ compact: Bool) -> [Date] {
        compact ? [cursor] : (0..<7).map { CalendarData.add(CalendarData.monday(cursor), days: $0) }
    }

    /// Identity for the visible range, so moving weeks cross-fades and slides.
    private func key(_ compact: Bool) -> String {
        CalendarData.format(CalendarData.monday(cursor), "yyyyMMdd")
    }

    private func move(_ dir: Int, _ compact: Bool) {
        step = dir
        if mode == .month {
            let d = CalendarData.cal.date(byAdding: .month, value: dir, to: cursor)!
            cursor = CalendarData.cal.dateInterval(of: .month, for: d)!.start
        } else {
            cursor = CalendarData.add(cursor, days: dir * (compact ? 1 : 7))
        }
    }

    private func controls(_ compact: Bool) -> some View {
        HStack(spacing: 8) {
            Segmented(options: [(Mode.week, compact ? "Day" : "Week"), (.month, "Month"), (.board, "Board")], selection: $mode)
            if compact { Spacer() }
            Button { edit = CalItem(id: 0, t: "", date: cursor, time: 10 * 60, project: filter) } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(BlackButton())
        }
    }

    private var chips: some View {
        PayFlow(spacing: 6) {
            PayChip("All", on: filter == nil) { filter = nil }
            ForEach(CalendarData.projects, id: \.name) { p in
                PayChip(on: filter == p.name, action: { filter = filter == p.name ? nil : p.name }) {
                    Circle().fill(p.color).frame(width: 7, height: 7)
                    Text(CalendarData.short(p.name))
                }
            }
        }
    }

    private func nav(_ compact: Bool) -> some View {
        let label = mode == .month || !compact ? CalendarData.format(cursor, "MMMM yyyy") : CalendarData.format(cursor, "EEE, MMM d")
        return HStack(spacing: 2) {
            Text(label).font(.system(size: 15, weight: .medium)).contentTransition(.numericText())
            Spacer()
            Button("Today") { step = cursor < CalendarData.today ? 1 : -1; cursor = CalendarData.today }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10).frame(height: PayMetrics.icon)
                .keyboardShortcut("t", modifiers: .command)
            PayIconButton(symbol: "chevron.left", label: "Previous") { move(-1, compact) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            PayIconButton(symbol: "chevron.right", label: "Next") { move(1, compact) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }
}
