import SwiftUI

// Notion-Calendar-style views over one list: Week (a day on iPhone), Month and Board.

enum CalGrid {
    static let start = 8, end = 20
    static let row: CGFloat = 48
    static let gutter: CGFloat = 48
    static var hours: [Int] { Array(start..<end) }
}

// MARK: Week / Day

struct CalWeekView: View {
    let days: [Date]
    let items: [CalItem]
    let compact: Bool
    let selected: Date
    let onPick: (Date) -> Void
    let onOpen: (CalItem) -> Void
    @Namespace var ns

    var body: some View {
        VStack(spacing: 12) {
            if compact { strip }
            VStack(spacing: 0) {
                if !compact { header }
                allDay
                grid
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        }
    }

    /// Mon–Sun strip above the single day on iPhone.
    private var strip: some View {
        let week = (0..<7).map { CalendarData.add(CalendarData.monday(selected), days: $0) }
        return HStack(spacing: 4) {
            ForEach(week, id: \.self) { d in
                let on = CalendarData.same(d, selected), today = CalendarData.same(d, CalendarData.today)
                Button { withAnimation(.snappy) { onPick(d) } } label: {
                    VStack(spacing: 3) {
                        Text(CalendarData.format(d, "EEEEE")).font(.system(size: 11)).foregroundStyle(on ? .white.opacity(0.8) : Theme.muted)
                        Text("\(CalendarData.dayNumber(d))").font(.system(size: 16, weight: .medium)).monospacedDigit()
                            .foregroundStyle(on ? .white : today ? Theme.accent : Theme.text)
                        Circle().fill(dot(d) ? (on ? Color.white : Theme.faint) : .clear).frame(width: 4, height: 4)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background {
                        if on { RoundedRectangle(cornerRadius: 11).fill(Theme.text).matchedGeometryEffect(id: "day", in: ns) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
    }

    private func dot(_ d: Date) -> Bool { items.contains { CalendarData.same($0.date, d) } }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CalGrid.gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = CalendarData.same(d, CalendarData.today)
                HStack(spacing: 4) {
                    Text(CalendarData.format(d, "EEE")).foregroundStyle(Theme.muted)
                    Text("\(CalendarData.dayNumber(d))").fontWeight(.medium).foregroundStyle(today ? Theme.accent : Theme.text)
                }
                .font(.system(size: 12.5))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                .contentShape(Rectangle())
                .onTapGesture { onPick(d) }
            }
        }
    }

    private var allDay: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("All day").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                .frame(width: CalGrid.gutter - 6, alignment: .trailing).padding(.trailing, 6).padding(.top, 9)
            ForEach(days, id: \.self) { d in
                VStack(spacing: 3) {
                    ForEach(items.filter { CalendarData.same($0.date, d) && $0.time == nil }) { t in
                        CalChip(item: t) { onOpen(t) }
                    }
                }
                .padding(4).frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        .payLine(!compact)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(CalGrid.hours, id: \.self) { h in
                    Text(String(format: "%d:00", h)).font(.system(size: 10.5)).foregroundStyle(Theme.faint).monospacedDigit()
                        .frame(width: CalGrid.gutter - 6, height: CalGrid.row, alignment: .topTrailing)
                        .padding(.trailing, 6).padding(.top, 2)
                }
            }
            ForEach(days, id: \.self) { d in
                CalDayColumn(day: d, items: items.filter { CalendarData.same($0.date, d) && $0.time != nil }, onOpen: onOpen)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        .payLine(true)
    }
}

/// One day of the time grid: hour lines, empty slots you can click to add, events, and the now line.
struct CalDayColumn: View {
    let day: Date
    let items: [CalItem]
    let onOpen: (CalItem) -> Void

    var body: some View {
        let height = CGFloat(CalGrid.hours.count) * CalGrid.row
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(CalGrid.hours, id: \.self) { h in
                        CalSlot(hour: h) { onOpen(CalItem(id: 0, t: "", date: day, time: h * 60)) }
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
                ForEach(lanes(), id: \.item.id) { e in
                    let t = e.item, lane = e.lane
                    let w = (g.size.width - 6) / CGFloat(e.count)
                    let top = max(0, CGFloat(t.time! - CalGrid.start * 60) / 60 * CalGrid.row)
                    let h = max(22, CGFloat(t.dur) / 60 * CalGrid.row - 2)
                    CalEventBlock(item: t, height: h) { onOpen(t) }
                        .frame(width: max(0, w - 2), height: min(h, height - top))
                        .offset(x: 3 + CGFloat(lane) * w, y: min(top, height - 22))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if CalendarData.same(day, CalendarData.today) { CalNowLine(height: height) }
            }
        }
        .frame(height: height)
    }

    /// Side by side lanes for overlapping events.
    private struct Placed { let item: CalItem; let lane: Int; let count: Int }

    private func lanes() -> [Placed] {
        func span(_ t: CalItem) -> Range<Int> { t.time!..<(t.time! + max(t.dur, 30)) }
        let sorted = items.sorted { ($0.time!, $0.id) < ($1.time!, $1.id) }
        return sorted.map { t in
            let group = sorted.filter { span($0).overlaps(span(t)) }
            return Placed(item: t, lane: group.firstIndex(of: t) ?? 0, count: max(1, group.count))
        }
    }
}

private struct CalSlot: View {
    let hour: Int
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(hover ? Theme.subtle : Color.clear)
                if hover {
                    Label(String(format: "%02d:00", hour), systemImage: "plus").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.faint).padding(.horizontal, 7).padding(.top, 5).transition(.opacity)
                }
            }
            .frame(height: CalGrid.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.15), value: hover)
        .accessibilityLabel("New at \(hour):00")
    }
}

/// The purple line at the current time. Ticks every minute.
private struct CalNowLine: View {
    let height: CGFloat
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let c = CalendarData.cal.dateComponents([.hour, .minute], from: ctx.date)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if m >= CalGrid.start * 60 && m <= CalGrid.end * 60 {
                let y = CGFloat(m - CalGrid.start * 60) / 60 * CalGrid.row
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.accent).frame(height: 2)
                    Circle().fill(Theme.accent).frame(width: 8, height: 8).offset(x: -4)
                }
                .offset(y: y - 1)
                .allowsHitTesting(false)
            }
        }
    }
}

struct CalEventBlock: View {
    let item: CalItem
    let height: CGFloat
    let action: () -> Void
    @State var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.t).font(.system(size: 12, weight: .medium)).lineLimit(height > 52 ? 2 : 1)
                    .strikethrough(item.status == .done)
                if height > 30, let t = item.timeText { Text(t).font(.system(size: 11)).foregroundStyle(Theme.muted).monospacedDigit() }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(item.color.opacity(hover ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(item.color).frame(width: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(item.status == .done ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.15), value: hover)
        .modifier(CalItemMenu(item: item, open: action))
    }
}

/// A one-line coloured chip (all-day items, month cells).
struct CalChip: View {
    let item: CalItem
    let action: () -> Void
    @State var hover = false
    var body: some View {
        Button(action: action) {
            Text(item.t).font(.system(size: 11.5, weight: .medium)).lineLimit(1).strikethrough(item.status == .done)
                .foregroundStyle(Theme.text)
                .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item.color.opacity(hover ? 0.2 : 0.12))
                .overlay(alignment: .leading) { Rectangle().fill(item.color).frame(width: 3) }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .opacity(item.status == .done ? 0.5 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .modifier(CalItemMenu(item: item, open: action))
    }
}

/// Right-click (Mac) / long-press (iPhone) menu on any calendar item.
struct CalItemMenu: ViewModifier {
    @Environment(AppModel.self) var model
    let item: CalItem
    let open: () -> Void
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open", systemImage: "arrow.up.right", action: open)
            if !item.event && !item.external {
                if item.status != .done {
                    Button("Mark done", systemImage: "checkmark.circle") { CalendarStore.shared.setStatus(item.id, .done) }
                } else {
                    Button("Mark not done", systemImage: "circle") { CalendarStore.shared.setStatus(item.id, .todo) }
                }
            }
            Button("Ask Hermit", systemImage: "sparkles") { model.newChat(project: item.project); model.send("Help me with \"\(item.t)\"") }
            if !item.external && !item.payment {
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    CalendarStore.shared.remove(item.id); model.toast("Deleted")
                }
            }
        }
    }
}

// MARK: Month

struct CalMonthView: View {
    let cursor: Date
    let items: [CalItem]
    let compact: Bool
    let onDay: (Date) -> Void
    let onOpen: (CalItem) -> Void

    var body: some View {
        let first = CalendarData.cal.dateInterval(of: .month, for: cursor)!.start
        let start = CalendarData.monday(first)
        let month = CalendarData.cal.component(.month, from: cursor)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(CalendarData.format(CalendarData.add(start, days: i), compact ? "EEEEE" : "EEE"))
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, compact ? 4 : 8).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
                }
            }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let d = CalendarData.add(start, days: w * 7 + i)
                        CalMonthCell(day: d, out: CalendarData.cal.component(.month, from: d) != month,
                                     items: items.filter { CalendarData.same($0.date, d) }.sorted { ($0.time ?? -1) < ($1.time ?? -1) },
                                     compact: compact, onDay: onDay, onOpen: onOpen)
                    }
                }
                .payLine(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

private struct CalMonthCell: View {
    let day: Date
    let out: Bool
    let items: [CalItem]
    let compact: Bool
    let onDay: (Date) -> Void
    let onOpen: (CalItem) -> Void
    @State var hover = false

    var body: some View {
        let today = CalendarData.same(day, CalendarData.today)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(CalendarData.dayNumber(day))").font(.system(size: 12.5, weight: today ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(today ? .white : out ? Theme.faint : Theme.text)
                .frame(minWidth: 22, minHeight: 22)
                .background(today ? Theme.accent : .clear, in: Circle())
            if compact {
                HStack(spacing: 2) {
                    ForEach(items.prefix(3)) { t in Capsule().fill(t.color).frame(height: 4) }
                }
            } else {
                ForEach(items.prefix(2)) { t in CalChip(item: t) { onOpen(t) } }
                if items.count > 2 {
                    Text("+\(items.count - 2)").font(.system(size: 11)).foregroundStyle(Theme.faint).padding(.leading, 2)
                }
            }
        }
        .padding(compact ? 4 : 6)
        .frame(maxWidth: .infinity, minHeight: compact ? 60 : 92, alignment: .topLeading)
        .background(hover ? Theme.hover.opacity(0.7) : out ? Theme.subtle : Theme.bg)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.smooth(duration: 0.3)) { onDay(day) } }
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.15), value: hover)
    }
}

// MARK: Board

struct CalBoard: View {
    let items: [CalItem]
    let compact: Bool
    let onOpen: (CalItem) -> Void
    @Namespace var ns

    var body: some View {
        let tasks = items.filter { !$0.event }
        let layout = compact ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach(CalStatus.allCases, id: \.self) { s in
                CalBoardColumn(status: s, cards: tasks.filter { $0.status == s }.sorted { $0.date < $1.date }, ns: ns, onOpen: onOpen)
            }
        }
    }
}

private struct CalBoardColumn: View {
    let status: CalStatus
    let cards: [CalItem]
    let ns: Namespace.ID
    let onOpen: (CalItem) -> Void
    @State var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.label).foregroundStyle(Theme.muted)
                Spacer()
                Text("\(cards.count)").foregroundStyle(Theme.faint).monospacedDigit().contentTransition(.numericText())
            }
            .font(.system(size: 13)).padding(.horizontal, 2).frame(minHeight: 24)
            ForEach(cards) { t in
                CalBoardCard(item: t, onOpen: onOpen)
                    .matchedGeometryEffect(id: t.id, in: ns)
                    .draggable("\(t.id)")
            }
            if cards.isEmpty {
                Text("Drop tasks here").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(targeted ? Theme.hover : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radius))
        .dropDestination(for: String.self) { ids, _ in
            for s in ids { if let id = Int(s) { CalendarStore.shared.setStatus(id, status) } }
            return true
        } isTargeted: { targeted = $0 }
        .animation(.snappy(duration: 0.2), value: targeted)
    }
}

private struct CalBoardCard: View {
    let item: CalItem
    let onOpen: (CalItem) -> Void
    @State var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.t).font(.system(size: 14, weight: .medium)).strikethrough(item.status == .done)
                .foregroundStyle(item.status == .done ? Theme.muted : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if item.project != nil { Circle().fill(item.color).frame(width: 7, height: 7) }
                Text(item.project.map(CalendarData.short) ?? "Personal").foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 6)
                Text(CalendarData.format(item.date, "MMM d")).foregroundStyle(Theme.faint).fixedSize()
            }
            .font(.system(size: 12.5)).padding(.top, 8)
            if item.status != .done {
                Button(item.status == .todo ? "Start" : "Mark done") {
                    CalendarStore.shared.setStatus(item.id, item.status == .todo ? .doing : .done)
                }
                .buttonStyle(PayPillButton(kind: .outline))
                .padding(.top, 10)
            }
        }
        .padding(12)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Color(hex: 0xD8D8D6) : Theme.border))
        .shadow(color: .black.opacity(hover ? 0.05 : 0), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onOpen(item) }
        .onHover { hover = $0 }
        .animation(.snappy(duration: 0.15), value: hover)
        .modifier(CalItemMenu(item: item) { onOpen(item) })
    }
}
