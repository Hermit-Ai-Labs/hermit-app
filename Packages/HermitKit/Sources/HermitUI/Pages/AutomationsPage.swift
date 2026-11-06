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
            Label("Scheduled runs are coming soon. Until then, open an automation and press Run now.", systemImage: "clock")
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
                Text(automation.trigger).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
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

extension AppModel {
    /// Runs an automation now: its prompt goes to Hermit in a new chat, the same way a typed message does.
    func runAutomation(_ name: String) {
        guard let i = automations.firstIndex(where: { $0.name == name }) else { return }
        guard !busy else { toast("Hermit is still answering. Try again in a moment."); return }
        let now = Date()
        let stamp = now.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        automations[i].lastRun = now
        automations[i].last = "Ran \(stamp)"
        automations[i].thread.append(Message(role: .assistant, text: "Ran in a new chat.", run: stamp))
        automationOpen = nil
        newChat(project: nil)
        send(automations[i].runPrompt)
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

    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// Reads the schedule out of a sentence ("every Monday at 9", "each morning", "every hour") and keeps the rest as the prompt.
    static func from(_ text: String) -> AutomationDraft {
        let t = text.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        let day = weekdays.first { t.contains($0) }
        var hh: String?
        if let re = try? NSRegularExpression(pattern: #"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text), !text[..<r.lowerBound].hasSuffix("$"),
           let h = Int(text[Range(m.range(at: 1), in: text)!]), h < 24 {
            let mins = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? "00"
            let ampm = Range(m.range(at: 3), in: text).map { text[$0].lowercased() }
            let hour = ampm == "pm" ? h % 12 + 12 : ampm == "am" ? h % 12 : (h < 7 && has("evening|night|afternoon") ? h + 12 : h)
            hh = String(format: "%02d:%@", hour, mins)
        }
        let fallback = has("evening") ? "18:00" : has("night") ? "21:00" : has("noon|lunch") ? "12:00" : has("morning") ? "08:00" : "09:00"
        let trigger: String
        if let d = day { trigger = "Every \(d.prefix(1).uppercased() + d.dropFirst()) \(hh ?? fallback)" }
        else if has(#"every hour|hourly"#) { trigger = "Every hour" }
        else if hh != nil || has(#"every|each|daily|morning|evening|night|day"#) { trigger = "Every day \(hh ?? fallback)" }
        else { trigger = "When you run it" }

        // The prompt: the sentence without its schedule words.
        var p = text
        for pattern in [#"(?i)\b(every|each)\s+(morning|evening|night|day|hour|week|weekday|"# + weekdays.joined(separator: "|") + #")s?\b"#,
                        #"(?i)\b(on\s+)?("# + weekdays.joined(separator: "|") + #")s?\b"#,
                        #"(?i)\b(daily|hourly)\b"#,
                        #"(?i)\b(at\s+\d{1,2}(:\d{2})?\s*(am|pm)?|\d{1,2}(:\d{2})?\s*(am|pm)|\d{1,2}:\d{2})\b"#] {
            p = p.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        p = p.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
        if p.isEmpty { p = text }
        p = p.prefix(1).uppercased() + p.dropFirst()
        let name = p.count > 44 ? String(p.prefix(42)).trimmingCharacters(in: .whitespaces) + "…" : p
        return AutomationDraft(name: name, trigger: trigger, action: p, limit: "No spending", prompt: p, asks: false)
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
                    Text(a.trigger).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
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
                    case .message(let m): MessageView(message: m)
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
                    TxLine("When", d.trigger)
                    TxLine("Asks Hermit", d.prompt)
                    Text(scheduled ? "Scheduled runs are coming soon. Until then it runs when you press Run now."
                                   : "It runs when you press Run now.")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 8)
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
            say(Message(role: .assistant, text: "Scheduled runs are coming soon, so there is nothing to pause yet. Say \"run it now\" to run it.", note: true))
        } else if has(#"every|each|daily|hourly|morning|evening|night|\b\d{1,2}\s*(am|pm)\b|\d{1,2}:\d{2}|"# + AutomationDraft.weekdays.joined(separator: "|")) {
            // "Make it every Tuesday at 10" changes the time; a longer sentence also replaces the prompt.
            let d = AutomationDraft.from(text)
            let scheduled = d.trigger != "When you run it"
            let newPrompt = d.prompt.count > 12 ? d.prompt : nil
            setAutomation {
                if scheduled { $0.trigger = d.trigger }
                if let p = newPrompt { $0.prompt = p; $0.action = p }
            }
            let when = scheduled ? d.trigger : a.trigger
            say(Message(role: .assistant, text: "Updated. \(when)\(newPrompt.map { ", it asks: \($0)" } ?? "").", note: true))
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
        say(Message(role: .assistant, text: "Saved. Press Run now to send it to Hermit. Reply here to change the time or the prompt.", note: true), after: 300)
        model.toast("Automation saved")
    }
}

/// Three dots while Hermit writes.
struct TypingDots: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Theme.faint).frame(width: 6, height: 6)
                    .phaseAnimator([0.3, 1.0]) { c, o in c.opacity(o) } animation: { _ in .smooth(duration: 0.5).delay(Double(i) * 0.15) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.hover, in: Capsule())
    }
}
