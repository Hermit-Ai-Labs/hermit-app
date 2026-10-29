import SwiftUI
import HermitCore

/// Automations, Claude-style: describe one in the chat box, Hermit drafts the rule, you turn it on.
/// Each automation is a conversation: what you asked for, then every run as a reply.
struct AutomationsPage: View {
    @Environment(AppModel.self) private var model

    static let examples = [
        "Every morning at 8, send me HYPE news on Telegram",
        "Buy $50 of ETH every Monday",
        "Alert me when HYPE funding goes above 0.03%",
        "Pay invoices from my inbox under $100",
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
            Composer(placeholder: "Describe an automation", label: "Automation", projectPicker: false,
                     dictation: "Every morning at 8, send me HYPE news on Telegram", autoFocus: false) { text, _ in
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
            ForEach(model.automations) { a in
                AutomationRow(automation: a)
                Divider().overlay(Theme.border)
            }
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
                .font(.system(size: 14)).foregroundStyle(automation.on ? Theme.accent : Theme.faint)
                .frame(width: 34, height: 34)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 2) {
                Text(automation.name).font(.system(size: 14, weight: .medium)).foregroundStyle(automation.on ? Theme.text : Theme.faint)
                Text(automation.trigger).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                Text(automation.last).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle(automation.name, isOn: Binding(get: { automation.on }, set: { _ in model.toggleAutomation(automation.name) }))
                .labelsHidden().toggleStyle(.switch).tint(Theme.text).controlSize(.small)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(hover ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { model.automationOpen = .existing(automation.name) }
        .onHover { h in withAnimation(.snappy(duration: 0.15)) { hover = h } }
        .padding(.horizontal, -8)
        .contextMenu {
            Button(automation.on ? "Pause" : "Turn on", systemImage: automation.on ? "pause" : "play") { model.toggleAutomation(automation.name) }
            Button("Open", systemImage: "bubble.left") { model.automationOpen = .existing(automation.name) }
        }
    }
}

/// What the model reads from a sentence: when, what, how much it may spend, and whether it asks first.
struct AutomationDraft: Equatable {
    var name, trigger, action, limit, prompt: String
    var asks: Bool

    /// Demo stand-in for the model drafting a rule from a sentence (same rules as the web demo).
    static func from(_ text: String) -> AutomationDraft {
        let t = text.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        func group(_ p: String, _ i: Int) -> String? {
            let s = text
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        let amt = group(#"\$\s?([\d,.]+)"#, 1)
        let day = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].first { t.contains($0) }
        var hh = "09:00"
        var timeFound = false
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#, options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range, in: text) {
            timeFound = true
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : " "
            if before != "$" {
                let h = Int(text[Range(m.range(at: 1), in: text)!]) ?? 9
                let mins = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? "00"
                let pm = Range(m.range(at: 3), in: text).map { text[$0].lowercased() == "pm" } ?? false
                hh = String(format: "%02d:%@", h % 12 + (pm ? 12 : 0), mins)
            }
        }
        let token = (group(#"\b(ETH|BTC|SOL|HYPE|PENGU|USDC)\b"#, 1) ?? "ETH").uppercased()
        let trigger: String
        if has("funding") { trigger = "\(token) funding > \(group(#"0\.\d+%"#, 0) ?? "0.03%")/h" }
        else if has(#"below|drops|under \$"#) && has("buy") { trigger = "\(token) below $\(amt ?? "3,200")" }
        else if has(#"above|over \$"#) && !has("invoice") { trigger = "\(token) above $\(amt ?? "27")" }
        else if has("invoice|bill") { trigger = "Invoice email arrives" }
        else if let d = day { trigger = "Every \(d.prefix(1).uppercased() + d.dropFirst()) \(hh)" }
        else if has("hour") { trigger = "Every hour" }
        else { trigger = "Every day \(has("morning") && !timeFound ? "08:00" : hh)" }
        let action: String
        if has("news|digest|brief") { action = "Send a \(token) news digest\(has("telegram") ? " on Telegram" : "")" }
        else if has("alert|tell me|notify") { action = "Send me an alert" }
        else if has("invoice|bill|pay") { action = "Pay the invoice\(amt.map { " if under $\($0)" } ?? "") in USDC" }
        else if has("sell|profit") { action = "Sell \(group(#"\d+%"#, 0) ?? "20%") of \(token)" }
        else if has("buy|dca") { action = "Buy \(amt.map { "$\($0)" } ?? "$100") of \(token) with USDC" }
        else { action = "Run the task and report back" }
        let spends = has("buy|sell|pay|invoice")
        var name = action
        for cut in [" with USDC", " in USDC", " on Telegram"] { if let r = name.range(of: cut) { name.removeSubrange(r); break } }
        name = name.replacingOccurrences(of: #"^Send (me )?(a |an )?"#, with: "", options: .regularExpression)
        name = name.prefix(1).uppercased() + name.dropFirst()
        return AutomationDraft(name: name, trigger: trigger, action: action, limit: spends ? "$\(amt ?? "100") per run" : "No spending",
                               prompt: text, asks: spends && !has("under"))
    }

    static func next(_ trigger: String) -> String {
        if trigger.hasPrefix("Every hour") { return "in 1 hour" }
        if trigger.hasPrefix("Every day") { return "tomorrow at \(trigger.suffix(5))" }
        if trigger.range(of: #"^Every \w+day"#, options: .regularExpression) != nil { return trigger.replacingOccurrences(of: "Every ", with: "next ") }
        return "when it happens"
    }
}

/// One automation's conversation: header with its switch, the thread, and a chat box to change it.
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
            Composer(placeholder: automation != nil ? "Change it, pause it, or \"run it now\"" : "Describe an automation", label: "Automation", projectPicker: false,
                     dictation: automation != nil ? "Run it now" : "Buy $50 of ETH every Monday") { text, _ in
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
                    Text(a.trigger + (a.on ? "" : ", paused")).font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer()
            if let a = automation {
                Toggle("Turn automation on or off", isOn: Binding(get: { a.on }, set: { _ in model.toggleAutomation(a.name) }))
                    .labelsHidden().toggleStyle(.switch).tint(Theme.text).controlSize(.small)
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
                    Text("Tell Hermit what to do and when. It drafts the rule, you turn it on.")
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
        return VStack(alignment: .leading, spacing: 10) {
            Text("Here is the automation. Check it, then turn it on.").font(.system(size: 14.5))
            ChatCard {
                Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(Theme.accent)
                CardTitle(d.name)
            } content: {
                VStack(spacing: 0) {
                    TxLine("When", d.trigger)
                    TxLine("Do", d.action)
                    TxLine("Spending", d.limit)
                    TxLine("Approval", d.asks ? "Ask me each time" : "Runs on its own")
                }
            } foot: {
                Button("Edit") { say(Message(role: .assistant, text: "Tell me what to change: the time, the amount, or what it does.", note: true), after: 300) }
                    .buttonStyle(PlainCardButton()).disabled(done)
                Button { turnOn(d) } label: { Label(done ? "On" : "Turn on", systemImage: "bolt.fill") }
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

    private func say(_ m: Message, after ms: Int = 700) {
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
                try? await Task.sleep(for: .milliseconds(SnapshotMode.active ? 0 : 700))
                typing = false
                items.append(.draft(d, UUID()))
            }
            return
        }
        if has("pause|stop|turn off") {
            setAutomation { $0.on = false; $0.last = "Paused by you" }
            say(Message(role: .assistant, text: "Paused. \(a.name) will not run until you turn it back on.", note: true))
        } else if has("resume|turn on|start") {
            setAutomation { $0.on = true }
            say(Message(role: .assistant, text: "Back on. Next run \(AutomationDraft.next(a.trigger)).", note: true))
        } else if has("run (it )?now|test") {
            let text = Automation.runs[a.name]?.first?.1 ?? "Ran as planned. Nothing needed your approval."
            setAutomation { $0.last = "Ran just now" }
            say(Message(role: .assistant, text: text, run: "Just now"), after: 1200)
        } else if has(#"every|daily|monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}(am|pm|:)"#) {
            let d = AutomationDraft.from(text)
            setAutomation { $0.trigger = d.trigger }
            say(Message(role: .assistant, text: "Updated. Now runs \(d.trigger.prefix(1).lowercased() + d.trigger.dropFirst()). Next run \(AutomationDraft.next(d.trigger)).", note: true))
        } else {
            say(Message(role: .assistant, text: "Got it. I will apply that from the next run and tell you what changed.", note: true))
        }
    }

    private func turnOn(_ d: AutomationDraft) {
        var a = Automation(name: d.name, trigger: d.trigger, action: d.action, limit: d.limit, on: true, last: "Just created", prompt: d.prompt, asks: d.asks, runs: [])
        a.thread = []
        model.addAutomation(a)
        name = d.name
        // The thread so far becomes the automation's history.
        for case .message(let m) in items { model.automations[0].thread.append(m) }
        say(Message(role: .assistant, text: "Automation on. Next run \(AutomationDraft.next(d.trigger)). \(d.asks ? "I will ask you before each one that spends money." : "Reply here to change it, or say \"run it now\" to test.")", note: true), after: 400)
        model.toast("Automation on")
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
