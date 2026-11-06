import SwiftUI

/// New or existing task / event: title, Task or Event, date, time, length, project, status,
/// then Open project, Open, Ask, Delete and Save. Device calendar events and scheduled payments open read only.
struct CalItemSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var f: CalItem
    @FocusState var titleFocused: Bool
    @State var picking = false

    init(item: CalItem) { _f = State(initialValue: item) }

    private static let times: [(Int, String)] = [(-1, "All day")] + stride(from: 6 * 60, through: 22 * 60, by: 30).map { ($0, CalendarData.clock($0)) }
    private static let lengths: [(Int, String)] = [(15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "1 h"), (90, "1.5 h"), (120, "2 h")]
    private var projectOptions: [(String, String)] { [("", "None")] + model.projectList.map { ($0.name, $0.name) } }
    private var store: CalendarStore { .shared }
    /// New events go to the device calendar when Hermit may write to it.
    private var toDevice: Bool { f.isNew && f.event && (store.access == .full || store.access == .writeOnly) }

    var body: some View {
        if f.external || f.payment { details } else { editor }
    }

    /// A device calendar event or a scheduled payment: what, when, where, plus Ask.
    private var details: some View {
        PaySheet(title: f.t) {
            PayLines(lines: detailLines)
            Text(f.payment ? "From your scheduled payments." : "From your calendar. Edit it in the Calendar app.")
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
        } foot: {
            if f.payment {
                Button("Open Payments") { dismiss(); model.open(.payments) }.buttonStyle(PayWideButton(kind: .plain))
            }
            Button { ask() } label: { Label("Ask Hermit", systemImage: "sparkles") }
                .buttonStyle(PayWideButton(kind: .accent))
        }
    }

    private var detailLines: [(String, String)] {
        var out: [(String, String)] = [("When", CalendarData.format(f.date, "EEE, MMM d") + (f.timeText.map { ", \($0)" } ?? ", all day"))]
        if let c = f.calendar { out.append(("Calendar", c)) }
        if let l = f.location, !l.isEmpty { out.append(("Where", l)) }
        return out
    }

    private var editor: some View {
        PaySheet {
            TextField(f.isNew ? "New task or event" : "Title", text: $f.t)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold)).tracking(-0.2)
                .focused($titleFocused)
                .onSubmit(save)
        } content: {
            CalWideSeg(options: [(false, "Task"), (true, "Event")], selection: $f.event)
                .disabled(!f.isNew && f.event)
            if f.isNew && f.event {
                Text(toDevice ? "Adds it to your calendar." : "Saved in Hermit. Allow calendar access to add events to your calendar.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Date") {
                    Button { picking = true } label: {
                        HStack {
                            Text(CalendarData.format(f.date, "EEE, MMM d")).font(.system(size: 14)).foregroundStyle(Theme.text)
                            Spacer(minLength: 6)
                            Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Theme.faint)
                        }
                        .payInputBox().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $picking) {
                        DatePicker("Date", selection: $f.date, displayedComponents: .date)
                            .labelsHidden().datePickerStyle(.graphical)
                            .frame(width: 280).padding(12)
                            .presentationCompactAdaptation(.popover)
                            .onChange(of: f.date) { _, _ in picking = false }
                    }
                }
                PayField(label: "Time") { PayMenuField(options: Self.times, selection: time) }
            }
            HStack(alignment: .top, spacing: 12) {
                PayField(label: "Length") { PayMenuField(options: Self.lengths, selection: $f.dur) }
                    .disabled(f.time == nil).opacity(f.time == nil ? 0.5 : 1)
                PayField(label: "Project") { PayMenuField(options: projectOptions, selection: project) }
            }
            if !f.event {
                PayField(label: "Status") { CalWideSeg(options: CalStatus.allCases.map { ($0, $0.label) }, selection: $f.status) }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !f.isNew {
                PayFlow(spacing: 8) {
                    if let p = f.project {
                        Button { dismiss(); model.openProject(p) } label: {
                            HStack(spacing: 6) { Circle().fill(f.color).frame(width: 7, height: 7); Text("Open project") }
                        }
                        .buttonStyle(PayPillButton(kind: .outline))
                    }
                    if f.to != nil || f.ask != nil {
                        Button { open() } label: { Label("Open", systemImage: "arrow.up.right") }
                            .buttonStyle(PayPillButton(kind: .outline))
                    }
                    Button { ask() } label: { Label("Ask", systemImage: "sparkles") }
                        .buttonStyle(PayPillButton(kind: .accent))
                }
            }
        } foot: {
            if !f.isNew {
                Button {
                    CalendarStore.shared.remove(f.id); dismiss(); model.toast("Deleted")
                } label: { Image(systemName: "trash").font(.system(size: 14)) }
                .buttonStyle(PayWideButton(kind: .plain)).frame(width: 52)
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityLabel("Delete")
            }
            Button(f.isNew ? "Add" : "Save", action: save)
                .buttonStyle(PayWideButton(kind: .black))
                .disabled(f.t.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .animation(.snappy(duration: 0.25), value: f.event)
        .onAppear { if f.isNew { titleFocused = true } }
    }

    private var time: Binding<Int> {
        Binding { f.time ?? -1 } set: { f.time = $0 < 0 ? nil : $0 }
    }
    private var project: Binding<String> {
        Binding { f.project ?? "" } set: { f.project = $0.isEmpty ? nil : $0; f.hex = model.project(f.project)?.hex }
    }

    private func save() {
        guard !f.t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var item = f
        item.date = CalendarData.cal.startOfDay(for: f.date)
        let isNew = item.isNew
        if toDevice && store.addToCalendar(item) {
            dismiss()
            model.toast("Added to your calendar")
            return
        }
        store.save(item)
        dismiss()
        model.toast(isNew ? "Added for \(CalendarData.format(item.date, "EEE, MMM d"))" : "Saved")
    }

    private func open() {
        dismiss()
        if let a = f.ask { model.send(a) } else if let to = f.to, let r = Route(rawValue: to) { model.open(r) }
    }

    private func ask() {
        dismiss()
        model.newChat(project: f.project)
        model.send("Help me with \"\(f.t)\"")
    }
}

/// Full-width segmented control for sheets (Task / Event, status).
struct CalWideSeg<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Namespace var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                let on = o.0 == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = o.0 } } label: {
                    Text(o.1).font(.system(size: 13, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.text : Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: PayMetrics.chip)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7).fill(Theme.bg)
                                    .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3).background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
    }
}
