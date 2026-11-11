import SwiftUI
import Observation
import HermitCore
import HermitWallet

// The v3 card tools: cancel an order, create an automation, schedule a payment reminder, save a contact. None of them
// moves money, so none needs the approval sheet; each one still needs the user. The tool only drafts: it puts a card
// in the chat that shows exactly what would happen (a contact's address in full, an automation's exact prompt), and
// the thing happens when the user taps the card's button, never from the tool call itself. What the model gets back
// says "card_opened" and that nothing is done yet; it never hears about the tap.

// MARK: The cards waiting for a tap

/// What each confirm card in the chat does when it is tapped, and how far it has got. Kept in memory only: a card read
/// back from a saved chat still shows what was drafted, with no button.
@MainActor @Observable
final class ToolCards {
    static let shared = ToolCards()

    enum State: Equatable {
        case waiting
        case working
        /// Done: the line posted in chat ("Saved: Alice, 0xAb58…eC9B").
        case done(String)
        /// It didn't go through: why. The button stays, to try again.
        case failed(String)
    }

    /// The work behind a card's button. It runs only from the tap, with the window's model. It returns the line to post
    /// in chat, or throws with a reason to show on the card.
    typealias Work = @MainActor (AppModel) async throws -> String

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var work: [String: Work] = [:]

    func add(_ card: ToolCard, work run: @escaping Work) {
        work[card.id] = run
        states[card.id] = .waiting
    }

    func state(_ id: String) -> State? { states[id] }

    /// The user tapped the card's button.
    func confirm(_ card: ToolCard, model: AppModel) async {
        guard let run = work[card.id], let now = states[card.id] else { return }
        switch now {
        case .waiting, .failed: break
        case .working, .done: return
        }
        states[card.id] = .working
        do {
            let line = try await run(model)
            states[card.id] = .done(line)
            work[card.id] = nil
            // A small line in chat. The model doesn't see it: on its next turn it reads the app's state with a tool.
            if model.route == .home, model.inChat {
                withAnimation(.smooth) { model.messages.append(Message(role: .assistant, text: line, note: true)) }
                model.commit()
            } else {
                model.toast(line)
            }
        } catch {
            states[card.id] = .failed(HermitToolbox.message(error))
        }
    }

    /// "Not now": the draft is dropped. Nothing was done.
    func dismiss(_ id: String) {
        work[id] = nil
        states[id] = nil
    }
}

/// A confirm card in chat: what would happen, a warning when there is one, and one button.
struct ToolConfirmCard: View {
    let card: ToolCard
    @Environment(AppModel.self) private var model
    private var store: ToolCards { .shared }

    private var symbol: String {
        switch card.kind {
        case "cancel_order": "xmark.circle"
        case "automation": "bolt"
        case "scheduled_payment": "calendar.badge.clock"
        case "contact": "person.crop.circle.badge.plus"
        default: "checkmark.circle"
        }
    }

    var body: some View {
        let state = store.state(card.id)
        ChatCard {
            Image(systemName: symbol).foregroundStyle(Theme.text).font(.system(size: 14))
            CardTitle(card.title)
            Spacer()
            tag(state)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(card.rows.enumerated()), id: \.offset) { _, r in row(r) }
                if let w = card.warning {
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if let n = card.note, state == .waiting {
                    Text(n).font(.system(size: 12)).foregroundStyle(Theme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if case .failed(let why)? = state {
                    Text(why).font(.system(size: 12.5)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
        } foot: {
            footer(state)
        }
    }

    @ViewBuilder private func tag(_ state: ToolCards.State?) -> some View {
        if let state {
            switch state {
            case .waiting: StatusTag(text: "Waiting for your tap", tone: .amber)
            case .working: StatusTag(text: "Working", tone: .text)
            case .done: StatusTag(text: "Done", tone: .green)
            case .failed: StatusTag(text: "Not done", tone: .red)
            }
        } else {
            StatusTag(text: "Not done", tone: .text)
        }
    }

    /// Short values sit beside their label. Long ones (an address, a prompt) go under it in full, never cut: the card is
    /// where the user checks them.
    @ViewBuilder private func row(_ r: [String]) -> some View {
        let key = r.first ?? "", value = r.count > 1 ? r[1] : ""
        if value.count <= 30 {
            TxLine(key, value)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(key).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Text(value)
                    .font(AddressText.looksLikeAddress(value) ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func footer(_ state: ToolCards.State?) -> some View {
        if let state {
            switch state {
            case .waiting, .failed:
                Button("Not now") { store.dismiss(card.id) }.buttonStyle(PlainCardButton())
                Button(card.confirm) { Task { await store.confirm(card, model: model) } }.buttonStyle(BrandButton())
            case .working:
                ProgressView().controlSize(.small)
                Text("One moment…").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            case .done(let line):
                Label(line, systemImage: "checkmark").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Nothing was done from this card. Ask Hermit again to open a new one.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: The tools

extension HermitToolbox {
    /// A card tool's outcome: the result for the model, and the card for the chat with its work registered.
    @MainActor static func card(_ card: ToolCard, result: [String: Any], work: @escaping ToolCards.Work) -> ToolOutcome {
        ToolCards.shared.add(card, work: work)
        var o = json(result)
        o.card = .confirm(card)
        return o
    }

    // MARK: cancel_order

    /// cancel_order: one open Hyperliquid order, take profit or stop loss, by id or by coin and kind; or every plain
    /// limit order with coin "all". The card names it and warns when it is the position's only stop loss.
    @MainActor static func cancelOrder(_ a: [String: Any]) async throws -> ToolOutcome {
        let hl = HyperliquidStore.shared
        guard hl.hasWallet, hl.trader() != nil else { throw ToolError("No wallet on \(Device.here) to trade with") }
        guard await hl.poll(), let account = hl.account else { throw ToolError("Couldn't read the Hyperliquid account") }
        let kind = ToolsV3.text(a, "kind")
        var id = ToolsV3.text(a, "order_id")
        if id.isEmpty, let n = a["order_id"] as? NSNumber { id = n.stringValue }
        switch ToolsV3.cancelPlan(coin: ToolsV3.text(a, "coin"), kind: kind.isEmpty ? nil : kind, orderID: id.isEmpty ? nil : id,
                                  orders: account.orders, positions: account.positions) {
        case .error(let e):
            throw ToolError(e)
        case .nothing(let note):
            return json(["status": "nothing_to_cancel", "prepared": false, "note": note])
        case .choose(let sym, let orders):
            return json(ToolsV3.cancelChoice(sym: sym, orders: orders))
        case .cancel(let orders, let text, let warning):
            let draft = ToolCard(kind: "cancel_order", title: orders.count == 1 ? "Cancel this order?" : "Cancel \(orders.count) orders?",
                                 rows: [["Cancel", text], ["On", "Hyperliquid"]], confirm: "Confirm", warning: warning,
                                 note: "Nothing is cancelled until you tap Confirm. \(Device.bio) then unlocks your key to sign the cancel.")
            var result: [String: Any] = ["status": "card_opened", "kind": "cancel_order", "executed": false, "cancelling": text,
                                         "note": "Waiting for the user to tap Confirm. Nothing is cancelled yet."]
            if let warning { result["warning"] = warning }
            return card(draft, result: result) { model in try await cancel(orders, text: text, model: model) }
        }
    }

    /// The tap on Confirm. One order goes through PerpActions.cancel, like the Cancel buttons on Trade; several go out
    /// as one cancel with one signature.
    @MainActor static func cancel(_ orders: [Hyperliquid.OpenOrder], text: String, model: AppModel) async throws -> String {
        let hl = HyperliquidStore.shared
        if orders.count == 1, let o = orders.first {
            if let problem = await PerpActions.cancel(o, model: model) { throw ToolError(problem) }
        } else {
            guard let trader = hl.trader() else { throw ToolError("Pick a wallet to trade with first.") }
            var items: [(assetID: Int, oid: Int)] = []
            for o in orders {
                guard let asset = await hl.asset(o.coin) else { throw ToolError("Couldn't find \(PerpFmt.sym(o.coin)) on Hyperliquid. Try again.") }
                items.append((assetID: asset.id, oid: o.oid))
            }
            try await trader.cancelMany(items, reason: "Cancel \(orders.count) orders on Hyperliquid")
            hl.refreshAfterTrade()
        }
        return "Cancelled: \(text)"
    }

    // MARK: create_automation

    /// create_automation: a prompt on a schedule, read by the same reader as the Automations page. The card shows the
    /// schedule as it will run and the exact prompt. An automation can look things up and prepare actions; every action
    /// it prepares still waits for the user's approval, as in any chat.
    @MainActor static func createAutomation(_ a: [String: Any]) -> ToolOutcome {
        let existing = ToolHost.shared.model?.automations.count ?? 0
        switch ToolsV3.automationPlan(name: ToolsV3.text(a, "name"), prompt: ToolsV3.text(a, "prompt"), schedule: ToolsV3.text(a, "schedule"), existing: existing) {
        case .error(let e):
            return json(["error": e, "prepared": false])
        case .blocked(let why):
            return json(ToolsV3.blocked([why]))
        case .ok(let name, let trigger, let schedule, let prompt):
            let draft = ToolCard(kind: "automation", title: "New automation",
                                 rows: [["Name", name], ["When", schedule], ["Asks Hermit", prompt], ["Money", "Never moves without your approval"]],
                                 confirm: "Create", note: "It runs on \(Device.here) while Hermit is open. Nothing is scheduled until you tap Create.")
            let result: [String: Any] = ["status": "card_opened", "kind": "automation", "executed": false, "name": name, "prompt": prompt,
                                         "schedule": schedule, "note": "Waiting for the user to tap Create. Nothing is scheduled yet."]
            return card(draft, result: result) { model in try saveAutomation(name: name, trigger: trigger, prompt: prompt, model: model) }
        }
    }

    /// The tap on Create: saved and switched on, like Save on the Automations page.
    @MainActor static func saveAutomation(name: String, trigger: String, prompt: String, model: AppModel) throws -> String {
        guard model.automations.count < ToolsV3.maxAutomations else {
            throw ToolError("You already have \(ToolsV3.maxAutomations) automations. Delete one in Automations first.")
        }
        var unique = name, k = 2
        while model.automations.contains(where: { $0.name == unique }) { unique = "\(name) \(k)"; k += 1 }
        // "In 2 minutes" counts from the tap, not from when the card was drafted.
        let pinned = Automation.pinned(trigger)
        model.addAutomation(Automation(name: unique, trigger: pinned, action: prompt, limit: "No spending", on: true, last: "Not run yet",
                                       prompt: prompt, asks: false, runs: []))
        AutomationScheduler.shared.askPermission()
        AutomationScheduler.shared.changed(model)
        let next = Automation.nextRun(pinned, after: Date()).map { " Next run \(Automation.dayText($0))." } ?? ""
        return "Automation created: \(unique)." + next
    }

    // MARK: schedule_payment

    /// schedule_payment: a reminder to pay a saved contact or a typed address, once or repeating. It never sends: when
    /// it is due the user taps Pay now, and that send has its own review and Face ID or Touch ID.
    @MainActor static func schedulePayment(_ a: [String: Any]) async -> ToolOutcome {
        let vm = WalletsViewModel.shared
        if vm.hasWallet, !vm.loaded { await vm.refresh() }
        let symbol = ToolsV3.text(a, "symbol").uppercased()
        var candidates: [ChainKind: [Chain]] = [:]
        for kind in [ChainKind.evm, .solana, .near] { candidates[kind] = ToolsV3.payChains(kind: kind, symbol: symbol) }
        var held: [String: Double] = [:]
        if let w = agentWallet {
            for chains in candidates.values { for c in chains { held[c.id] = vm.balance(of: symbol, wallet: w.id, chain: c) } }
        }
        let chain = ToolsV3.text(a, "chain"), repeats = ToolsV3.text(a, "repeat")
        switch ToolsV3.paymentPlan(payee: ToolsV3.text(a, "payee"), amountText: ToolsV3.decimalText(a, "amount"), symbol: symbol, when: ToolsV3.text(a, "when"),
                                   chain: chain.isEmpty ? nil : chain, repeats: repeats.isEmpty ? nil : repeats,
                                   payees: PaymentsStore.shared.payees, candidates: candidates, held: held) {
        case .error(let e):
            return json(["error": e, "prepared": false])
        case .payeeNotFound(let name):
            return json(["status": "payee_not_found", "prepared": false,
                         "note": "No saved contact called \(name). Ask the user for the address, or to save the contact first."])
        case .chooseContact(let name, let options):
            return json(["status": "needs_choice", "prepared": false, "options": options, "question": "Which \(name)? \(ToolsV3.either(options)).",
                         "note": ToolsV3.askWhich])
        case .chooseChain(let sym, let options):
            return json(ToolsV3.chainChoice(symbol: sym, options: options))
        case .ok(let payment, let network, let shown):
            let amount = "\(payment.sendAmount) \(payment.token)", due = ToolsV3.stamp(payment.next)
            let draft = ToolCard(kind: "scheduled_payment", title: "Payment reminder",
                                 rows: [["To", payment.payee], ["Address", payment.addr], ["Amount", amount], ["Network", network.name],
                                        ["First due", due], ["Repeats", payment.repeats.label],
                                        ["Sends by itself", "No. You approve each payment"]],
                                 confirm: "Schedule",
                                 note: "This is a reminder. When it is due you tap Pay now and approve the send with \(Device.bio).")
            let result: [String: Any] = ["status": "card_opened", "kind": "scheduled_payment", "executed": false, "payee": shown, "amount": amount,
                                         "network": network.name, "next_due": due, "repeat": payment.repeats.rawValue,
                                         "note": "Waiting for the user to tap Schedule. This is a reminder: nothing is sent by itself, and the user approves each payment with \(Device.bio) when it is due."]
            return card(draft, result: result) { _ in
                PaymentsStore.shared.save(payment)
                return "Reminder scheduled: \(amount) to \(shown), first due \(due). Nothing is sent until you approve it."
            }
        }
    }

    // MARK: add_contact

    /// add_contact: a name for an address the user typed in this chat (ToolGuard refuses any other). The card shows
    /// the address in full, because that card is the check: a wrong or planted address must be seen before it is saved.
    @MainActor static func addContact(_ a: [String: Any]) -> ToolOutcome {
        let network = ToolsV3.text(a, "network")
        let saved = PaymentsStore.shared.payees.map { ToolsV3.Contact(name: $0.name, address: $0.addr) }
        switch ToolsV3.contactPlan(name: ToolsV3.text(a, "name"), address: ToolsV3.text(a, "address"), network: network.isEmpty ? nil : network, payees: saved) {
        case .error(let e):
            return json(["error": e])
        case .nameTaken(let name):
            return json(["status": "name_taken", "prepared": false,
                         "note": "A contact called \(name) already exists with another address. Ask the user for a different name."])
        case .exists(let name):
            return json(["status": "exists", "prepared": false, "note": "\(name) is already saved with that address."])
        case .ok(let name, let address, let kind):
            let draft = ToolCard(kind: "contact", title: "New contact", rows: [["Name", name], ["Address", address], ["Works on", kind.familyName]],
                                 confirm: "Save", note: "Check every character of the address. Saving it sends nothing.")
            let result: [String: Any] = ["status": "card_opened", "kind": "contact", "executed": false, "name": name, "address": address,
                                         "network": kind.shortName,
                                         "note": "Waiting for the user to tap Save. The card shows the full address; nothing is sent."]
            return card(draft, result: result) { _ in
                let store = PaymentsStore.shared
                guard store.payee(named: name) == nil else { throw ToolError("A contact called \(name) was saved in the meantime.") }
                store.save(Payee(name: name, addr: address))
                return "Saved: \(name), \(shortAddr(address))."
            }
        }
    }
}
