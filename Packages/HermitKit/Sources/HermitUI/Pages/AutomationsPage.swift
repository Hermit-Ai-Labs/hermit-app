import SwiftUI
import HermitCore

/// Automations, Claude-style: describe one in the chat box, Hermit drafts the rule (a prompt and a schedule), you save it.
/// Each automation is a conversation: what you asked for, then every run. Run now sends the prompt to Hermit in a new chat.
struct AutomationsPage: View {
    @Environment(AppModel.self) private var model

    static let examples = [
        "Every morning at 8, give me three priorities for the day",
        "Every Friday at 5pm, help me review my week",
        "Every Monday at 9, remind me to check my budget",
        "Every evening at 9, ask me what went well today",
    ]

    var body: some View {
        Group {
            if let open = model.automationOpen {
                AutomationThread(start: open)
                    .id(open)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            } else {
                ScrollPage(maxWidth: 720) { list }.transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.automationOpen)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Automations").font(.system(size: 26, weight: .semibold)).tracking(-0.4)
                Spacer()
                Button { model.automationOpen = .new("") } label: { Label("New", systemImage: "plus") }
                    .buttonStyle(BlackButton())
            }
            Composer(placeholder: "Describe an automation", label: "", projectPicker: false,
                     dictation: Self.examples[0], autoFocus: false) { text, _ in
                if !text.isEmpty { model.automationOpen = .new(text) }
            }
            .padding(.top, 20)
            Flow(spacing: 8) {
                ForEach(Self.examples, id: \.self) { e in
                    Button(e) { model.automationOpen = .new(e) }.buttonStyle(ChipStyle())
                }
            }
            .padding(.top, 12).padding(.bottom, 26)
            Divider().overlay(Theme.border)
            if model.automations.isEmpty {
                EmptyNote(text: "No automations yet. Describe one above or pick an example.")
            }
            ForEach(model.automations) { a in
                AutomationRow(automation: a)
                Divider().overlay(Theme.border)
            }
            Label("Automations run when you press Run now. Schedules are coming soon.", systemImage: "play")
                .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 14)
        }
    }
}

struct AutomationRow: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: automation.isSchedule ? "clock" : "bolt")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                .frame(width: 34, height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(automation.plannedText).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Text(automation.last).font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            }
            Spacer()
            Button("Run now") { model.runAutomation(automation.name) }.buttonStyle(OutlineButton())
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(hover ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { model.automationOpen = .existing(automation.name) }
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .padding(.horizontal, -8)
        .contextMenu {
            Button("Run now", systemImage: "play") { model.runAutomation(automation.name) }
            Button("Open", systemImage: "bubble.left") { model.automationOpen = .existing(automation.name) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteAutomation(automation.name) }
        }
    }
}

extension Automation {
    /// The trigger as a plan: schedules don't run by themselves yet, so they read "Planned: Every Monday 09:00".
    var plannedText: String { isSchedule ? "Planned: \(trigger)" : trigger }
}

extension AppModel {
    /// Runs an automation now: its prompt goes to Hermit in a new chat, the same way a typed message does. The run is
    /// logged only once that chat has started, with a link back to it, so the history never claims a run that didn't begin.
    func runAutomation(_ name: String) {
        guard let i = automations.firstIndex(where: { $0.name == name }) else { return }
        guard !busy else { toast("Hermit is still answering. Try again in a moment."); return }
        let prompt = automations[i].runPrompt
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { toast("This automation has no prompt yet"); return }
        automationOpen = nil
        newChat(project: nil)
        send(prompt)
        guard busy, let chat = currentID, let j = automations.firstIndex(where: { $0.name == name }) else {
            toast("Couldn't start the run. Try again."); return
        }
        let now = Date()
        let stamp = now.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        automations[j].lastRun = now
        automations[j].last = "Last run \(stamp)"
        automations[j].thread.append(Message(role: .assistant, text: "Sent to Hermit in a new chat.", actions: [AutomationThread.openChat(chat)], run: stamp))
    }

    func deleteAutomation(_ name: String) {
        withAnimation(.snappy) { automations.removeAll { $0.name == name } }
        if automationOpen == .existing(name) { automationOpen = nil }
        toast("Automation deleted")
    }
}

/// What a sentence becomes: a name, when it runs, and the prompt each run sends.
struct AutomationDraft: Equatable {
    var name, trigger, action, limit, prompt: String
    var asks: Bool
    /// Set when the sentence asks for a schedule Hermit can't plan yet ("every 15 minutes", weekdays, monthly): says so.
    var note: String? = nil

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// Reads the schedule out of a sentence ("every Monday at 9", "each morning", "every hour") and keeps the rest as the prompt.
    /// Schedules the trigger can't hold (every 15 minutes, weekdays, two weekdays, monthly) become "When you run it" with a note.
    static func from(_ text: String) -> AutomationDraft {
        let t = text.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        func found(_ p: String) -> String? { t.range(of: p, options: .regularExpression).map { String(t[$0]) } }
        let days = weekdays.filter { t.contains($0) }
        let time = clock(text, evening: has("evening|night|afternoon|tonight"))
        let fallback = has("evening") ? "18:00" : has("midnight") ? "00:00" : has("night") ? "21:00" : has("noon|lunch") ? "12:00"
            : has("morning") ? "08:00" : "09:00"

        var unsupported: String?
        var hourly = false, daily = false
        if let phrase = found(#"\b(every|each)\s+\d+\s*(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#) {
            // "every 1 hour" and "every 1 day" fit the trigger; any other count doesn't yet.
            let n = Int(phrase.filter(\.isNumber))
            if n == 1, phrase.contains("hour") || phrase.contains("hr") { hourly = true }
            else if n == 1, phrase.contains("day") { daily = true }
            else { unsupported = phrase }
        }
        if unsupported == nil { unsupported = found(#"\bweekdays?\b|\bweekends?\b|\b(every|each)\s+other\s+\w+"#) }
        if unsupported == nil, days.isEmpty { unsupported = found(#"\bweekly\b|\b(every|each)\s+week\b"#) }
        if unsupported == nil, days.count > 1 { unsupported = days.map { (d: String) -> String in d.prefix(1).uppercased() + d.dropFirst() }.joined(separator: " and ") }
        if unsupported == nil {
            unsupported = found(#"\b(every|each)\s+(month|year)\b|\bmonthly\b|\byearly\b|\bannually\b|\bon\s+the\s+\d{1,2}(st|nd|rd|th)\b"#)
        }

        let trigger: String
        if unsupported != nil { trigger = "When you run it" }
        else if let d = days.first { trigger = "Every \(d.prefix(1).uppercased() + d.dropFirst()) \(time?.hh ?? fallback)" }
        else if hourly || has(#"\b(every|each) hour\b|\bhourly\b"#) { trigger = "Every hour" }
        else if daily || time != nil
                    || has(#"\b(every|each)\s+(single\s+)?(day|morning|evening|night|afternoon)s?\b|\b(daily|everyday|nightly)\b|\b(mornings|evenings|nights)\b"#) {
            trigger = "Every day \(time?.hh ?? fallback)"
        }
        else { trigger = "When you run it" }

        // The prompt: the sentence without its schedule words. The time found above goes first, by its exact place.
        var p = text
        if let r = time?.range { p = (p as NSString).replacingCharacters(in: r, with: " ") }
        let wd = weekdays.joined(separator: "|")
        for pattern in [#"(?i)\b(every|each)\s+\d+\s*(minutes?|mins?|hours?|hrs?|days?|weeks?|months?)\b"#,
                        #"(?i)\b((every|each|on)\s+(other\s+)?)?("# + wd + #")s?(\s*(,|&|\band\b|\bor\b)\s*("# + wd + #")s?)*\b"#,
                        #"(?i)\b(every|each)\s+(other\s+)?(single\s+)?(morning|evening|night|afternoon|day|hour|week|weekday|weekend|month|year)s?\b"#,
                        #"(?i)\b(on\s+)?(weekdays?|weekends?)\b"#,
                        #"(?i)\b(daily|hourly|weekly|monthly|yearly|annually|nightly|everyday)\b"#,
                        #"(?i)\bon\s+the\s+\d{1,2}(st|nd|rd|th)\b"#,
                        #"(?i)\b(in\s+the\s+(morning|evening|afternoon)|at\s+(night|noon|midnight))\b"#] {
            p = p.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let edges = CharacterSet.whitespaces.union(.punctuationCharacters)
        p = p.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([,;:])(\s*[,;:])+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: edges)
        // Words left hanging where the schedule was cut out: "and brief me", "check prices on".
        p = p.replacingOccurrences(of: #"(?i)^(and|then|to|please)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+(and|on|at|every|each|to)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: edges)
        if p.isEmpty { p = text }
        p = p.prefix(1).uppercased() + p.dropFirst()
        let name = p.count > 44 ? String(p.prefix(42)).trimmingCharacters(in: .whitespaces) + "…" : p
        let note = unsupported.map { "Hermit can't plan \"\($0)\" yet, so it runs when you press Run now." }
        return AutomationDraft(name: name, trigger: trigger, action: p, limit: "No spending", prompt: p, asks: false, note: note)
    }

    /// The time of day in a sentence as "HH:mm", and where it is. Only a number that reads as a time counts: after "at",
    /// before am or pm, or written 17:30. So "top 5 gainers" and "every 2 hours" have no time, and a number right after
    /// "$" is an amount. With no am or pm, "evening at 9" is 21:00.
    static func clock(_ text: String, evening: Bool) -> (hh: String, range: NSRange)? {
        let pattern = #"\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?![\d%:])|\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if m.range.location > 0, ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) == "$" { continue }
            guard let h = Int(group(1) ?? group(4) ?? group(7) ?? ""), let mins = Int(group(2) ?? group(5) ?? group(8) ?? "00"), mins < 60 else { continue }
            let ampm = (group(3) ?? group(6))?.lowercased()
            let hour: Int
            if let ampm {
                guard (1...12).contains(h) else { continue }
                hour = ampm == "pm" ? h % 12 + 12 : h % 12
            } else {
                guard h < 24 else { continue }
                hour = evening && (1...11).contains(h) ? h + 12 : h
            }
            return (String(format: "%02d:%02d", hour, mins), m.range)
        }
        return nil
    }

    /// "Mon 09:00" for a schedule, or how it runs otherwise.
    static func next(_ trigger: String) -> String {
        guard let d = Automation.nextRun(trigger, after: Date()) else { return "when you press Run now" }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// One automation's conversation: header with Run now and a menu, the thread, and a chat box to change it.
struct AutomationThread: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compact) private var compact
    let start: AppModel.AutomationOpen

    enum Item: Equatable, Identifiable {
        case message(Message), draft(AutomationDraft, UUID)
        var id: UUID { switch self { case .message(let m): m.id; case .draft(_, let id): id } }
    }

    @State private var name: String?
    @State private var items: [Item] = []
    @State private var typing = false
    @State private var loaded = false

    private var automation: Automation? { model.automations.first { $0.name == name } }

    /// A run's thread message keeps the chat it started as an action ("chat:<id>"), shown here as Open the chat.
    /// Run messages never show their actions in MessageView, so it isn't tappable anywhere else.
    static func openChat(_ id: String) -> Action { Action("Open the chat", open: "chat:" + id) }
    static func chatID(_ m: Message) -> String? {
        m.actions.compactMap { $0.open }.first { $0.hasPrefix("chat:") }.map { String($0.dropFirst("chat:".count)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                if SnapshotMode.active { thread.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else {
                    ScrollView { thread }
                        .defaultScrollAnchor(.bottom, for: .sizeChanges)
                        .scrollDismissesKeyboard(.interactively)
                }
            }
            Composer(placeholder: automation != nil ? "Change the time or the prompt, or \"run it now\"" : "Describe an automation", label: "", projectPicker: false,
                     dictation: automation != nil ? "Run it now" : AutomationsPage.examples[1]) { text, _ in
                if !text.isEmpty { send(text) }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, compact ? 12 : 28).padding(.bottom, compact ? 8 : 20).padding(.top, 4)
        }
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.automationOpen = nil } label: {
                Image(systemName: "arrow.left").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(ToolStyle()).help("All automations").keyboardShortcut("[", modifiers: .command)
            VStack(alignment: .leading, spacing: 1) {
                Text(automation?.name ?? "New automation").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let a = automation {
                    Text(a.plannedText).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            if let a = automation {
                Button("Run now") { model.runAutomation(a.name) }.buttonStyle(OutlineButton())
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteAutomation(a.name) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.horizontal, compact ? 12 : 22).padding(.vertical, 10)
        .animation(.snappy, value: automation)
    }

    private var thread: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if items.isEmpty && !typing {
                VStack(spacing: 14) {
                    HermitMark(height: 18)
                    Text("Tell Hermit what to ask and when. It drafts the automation, you save it.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Flow(spacing: 8) {
                        ForEach(AutomationsPage.examples, id: \.self) { e in Button(e) { send(e) }.buttonStyle(ChipStyle()) }
                    }
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            }
            ForEach(items) { item in
                Group {
                    switch item {
                    case .message(let m):
                        VStack(alignment: .leading, spacing: 6) {
                            MessageView(message: m)
                            if m.run != nil, let id = AutomationThread.chatID(m), model.conversations.contains(where: { $0.id == id }) {
                                Button("Open the chat") { model.openConversation(id) }.buttonStyle(PlainCardButton())
                            }
                        }
                    case .draft(let d, _): draftCard(d)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
            if typing { TypingDots().transition(.opacity) }
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, compact ? 16 : 28).padding(.vertical, 28)
        .animation(.smooth(duration: 0.3), value: items)
        .animation(.smooth(duration: 0.2), value: typing)
    }

    private func draftCard(_ d: AutomationDraft) -> some View {
        let done = automation != nil
        let scheduled = Automation.nextRun(d.trigger, after: Date()) != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Here is the automation. Check it, then save it.").font(.system(size: 14.5))
            ChatCard {
                Image(systemName: scheduled ? "clock" : "bolt").font(.system(size: 12)).foregroundStyle(Theme.muted)
                CardTitle(d.name)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    TxLine(scheduled ? "Planned" : "When", d.trigger)
                    TxLine("Asks Hermit", d.prompt)
                    Text(d.note ?? (scheduled ? "Runs when you press Run now. Schedules are coming soon." : "It runs when you press Run now."))
                        .font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            } foot: {
                Button("Edit") { say(Message(role: .assistant, text: "Tell me what to change: the time or what to ask.", note: true), after: 300) }
                    .buttonStyle(PlainCardButton()).disabled(done)
                Button { save(d) } label: { Label(done ? "Saved" : "Save", systemImage: "checkmark") }
                    .buttonStyle(BrandButton()).disabled(done)
            }
        }
    }

    // MARK: Behaviour

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch start {
        case .existing(let n):
            name = n
            items = (model.automations.first { $0.name == n }?.thread ?? []).map { .message($0) }
        case .new(let text):
            if !text.isEmpty { send(text) }
        }
    }

    private func append(_ m: Message) {
        items.append(.message(m))
        if let n = name, let i = model.automations.firstIndex(where: { $0.name == n }) { model.automations[i].thread.append(m) }
    }

    private func say(_ m: Message, after ms: Int = 500) {
        typing = true
        Task {
            try? await Task.sleep(for: .milliseconds(SnapshotMode.active ? 0 : ms))
            typing = false
            append(m)
        }
    }

    private func setAutomation(_ change: (inout Automation) -> Void) {
        guard let n = name, let i = model.automations.firstIndex(where: { $0.name == n }) else { return }
        withAnimation(.snappy) { change(&model.automations[i]) }
    }

    private func send(_ text: String) {
        append(Message(role: .user, text: text))
        let t = text.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        guard let a = automation else {
            let d = AutomationDraft.from(text)
            typing = true
            Task {
                try? await Task.sleep(for: .milliseconds(SnapshotMode.active ? 0 : 500))
                typing = false
                items.append(.draft(d, UUID()))
            }
            return
        }
        if has(#"^(run( it)?( now)?|test( it)?)[.!]?$"#) {
            model.runAutomation(a.name)
        } else if has(#"^(pause|stop|turn (it )?off|resume|turn (it )?on|start)"#) {
            say(Message(role: .assistant, text: "There is nothing to pause: it only runs when you ask. Say \"run it now\" to run it.", note: true))
        } else if has(#"every|each|daily|hourly|morning|evening|night|\b\d{1,2}\s*(am|pm)\b|\d{1,2}:\d{2}|"# + AutomationDraft.weekdays.joined(separator: "|")) {
            // "Make it every Tuesday at 10" changes the time; a longer sentence also replaces the prompt.
            let d = AutomationDraft.from(text)
            let scheduled = d.trigger != "When you run it"
            let newPrompt = d.prompt.count > 12 ? d.prompt : nil
            setAutomation {
                if scheduled { $0.trigger = d.trigger }
                if let p = newPrompt { $0.prompt = p; $0.action = p }
            }
            let when = scheduled ? "Planned: \(d.trigger)" : a.plannedText
            let changed = "Updated. \(when)\(newPrompt.map { ", it asks: \($0)" } ?? "")."
            say(Message(role: .assistant, text: d.note.map { changed + " " + $0 } ?? changed, note: true))
        } else {
            setAutomation { $0.prompt = text; $0.action = text }
            say(Message(role: .assistant, text: "Updated. Each run now asks: \(text)", note: true))
        }
    }

    private func save(_ d: AutomationDraft) {
        var n = d.name, k = 2
        while model.automations.contains(where: { $0.name == n }) { n = "\(d.name) \(k)"; k += 1 }
        var a = Automation(name: n, trigger: d.trigger, action: d.action, limit: d.limit, on: false, last: "Not run yet", prompt: d.prompt, asks: d.asks, runs: [])
        a.thread = []
        model.addAutomation(a)
        name = n
        // The thread so far becomes the automation's history.
        for case .message(let m) in items { model.automations[0].thread.append(m) }
        say(Message(role: .assistant, text: "Saved. It runs when you press Run now. Schedules are coming soon. Reply here to change the time or the prompt.", note: true), after: 300)
        model.toast("Automation saved")
    }
}

/// Three dots while Hermit writes. With Reduce Motion on they stay still.
struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                if reduceMotion {
                    Circle().fill(Theme.faint).frame(width: 6, height: 6)
                } else {
                    Circle().fill(Theme.faint).frame(width: 6, height: 6)
                        .phaseAnimator([0.3, 1.0]) { c, o in c.opacity(o) } animation: { _ in .smooth(duration: 0.5).delay(Double(i) * 0.15) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.hover, in: Capsule())
    }
}
