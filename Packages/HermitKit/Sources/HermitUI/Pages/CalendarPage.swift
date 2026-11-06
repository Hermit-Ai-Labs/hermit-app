import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Calendar (Notion Calendar-style): Week (a day with a week strip on iPhone), Month and Board over your device
/// calendar's events (with permission), tasks and events you add here, and scheduled payments. Project filter chips,
/// Today and arrows, click an empty slot to add, click an item to open it.
struct CalendarPage: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode = .week
    @State private var cursor = CalendarData.today
    @State private var filter: String?
    @State private var edit: CalItem?
    @State private var width: CGFloat = 1000
    @State private var step = 1
    @Environment(\.openURL) private var openURL
    private var store: CalendarStore { .shared }

    enum Mode: String, Hashable { case week, month, board }

    var body: some View {
        let compact = width < 700
        Page(title: "Calendar", tabs: [(0, "Calendar")], tab: .constant(0)) {
            if !compact { controls(compact) }
        } content: { _ in
            VStack(alignment: .leading, spacing: 16) {
                if compact { controls(compact) }
                access
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
        .onChange(of: cursor) { _, d in store.show(around: d) }
        .onAppear {
            store.refreshAccess()
            store.show(around: cursor)
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
            Button { edit = CalItem(id: 0, t: "", date: cursor, time: 10 * 60, project: filter, hex: model.project(filter)?.hex) } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(BlackButton())
        }
    }

    /// Projects that have something on the calendar.
    private var projects: [Project] { model.projectList.filter { p in store.items.contains { $0.project == p.name } } }

    @ViewBuilder private var chips: some View {
        if !projects.isEmpty {
            PayFlow(spacing: 6) {
                PayChip("All", on: filter == nil) { filter = nil }
                ForEach(projects) { p in
                    PayChip(on: filter == p.name, action: { filter = filter == p.name ? nil : p.name }) {
                        Circle().fill(p.color).frame(width: 7, height: 7)
                        Text(CalendarData.short(p.name))
                    }
                }
            }
        }
    }

    /// Asks for calendar access, or explains how to turn it back on.
    @ViewBuilder private var access: some View {
        switch store.access {
        case .full: EmptyView()
        case .unknown:
            banner("Show your calendar here", "Hermit reads your events on this device. Nothing leaves it.") {
                Button("Allow access") { Task { await store.requestAccess() } }.buttonStyle(BlackButton())
            }
        case .writeOnly, .denied:
            banner(store.access == .denied ? "Calendar access is off" : "Hermit can add events but not read them",
                   "Turn on full access to Calendars for Hermit in Settings to see your events here.") {
                Button("Open Settings") { openSettings() }.buttonStyle(OutlineButton())
            }
        }
    }

    private func banner<B: View>(_ title: String, _ text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            button()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func openSettings() {
        #if os(macOS)
        let s = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        #else
        let s = UIApplication.openSettingsURLString
        #endif
        if let u = URL(string: s) { openURL(u) }
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
