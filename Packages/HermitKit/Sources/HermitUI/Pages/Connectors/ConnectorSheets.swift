import SwiftUI
import LocalAuthentication
import HermitCore
import HermitWallet

// MARK: Binance

/// Connect Binance with an API key made on binance.com (API Management). Checked against Binance before it's saved.
struct BinanceConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    let done: () -> Void
    private var store: ConnectorStore { .shared }

    var body: some View {
        SheetChrome(title: "Connect Binance", subtitle: "With your own API key") {
            HStack(spacing: 14) {
                LogoMark("hermit", size: 40)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)).foregroundStyle(Theme.faint)
                LogoMark("binance", size: 40)
            }
            .frame(maxWidth: .infinity)
            FormField(label: "API key") { secureField("Paste the API key", text: $key) }
            FormField(label: "Secret key") { secureField("Paste the secret key", text: $secret) }
            NoteBox(symbol: "key", text: "On Binance: Profile → API Management → Create API. Leave Withdrawals off. Turn on Spot trading only if you want Hermit to place orders.")
            NoteBox(symbol: "lock.shield", text: "The key is saved in \(Device.here)'s Keychain and sent only to Binance.")
            Button("Open Binance API Management") { openURL(URL(string: "https://www.binance.com/en/my/settings/api-management")!) }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button {
                Task {
                    busy = true; error = nil
                    do { try await store.connectBinance(key: key, secret: secret); dismiss(); done() }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Checking" : "Connect") }
            }
            .buttonStyle(WideButton()).disabled(key.count < 20 || secret.count < 20 || busy)
        }
    }

    private func secureField(_ p: String, text: Binding<String>) -> some View {
        SecureField(p, text: text).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .modifier(FieldBox())
    }
}

/// The connected Binance account: balances valued in USDT, a quick market buy/sell (through the review sheet with
/// Face ID / Touch ID), open orders, disconnect.
struct BinanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var prices: [String: Double] = [:]
    @State private var orders: [Binance.Order] = []
    @State private var side = "buy"
    @State private var asset = "BTC"
    @State private var amount = ""
    @State private var busy = false
    @State private var error: String?
    @Environment(\.askApproval) private var ask
    private var store: ConnectorStore { .shared }

    private func usd(_ b: Binance.Balance) -> Double {
        if ["USDT", "USDC", "FDUSD"].contains(b.asset) { return b.total }
        return b.total * (prices[b.asset + "USDT"] ?? 0)
    }
    private var balances: [Binance.Balance] { (store.binanceAccount?.balances ?? []).sorted { usd($0) > usd($1) } }
    private var usdt: Double { store.binanceAccount?.balances.first { $0.asset == "USDT" }?.free ?? 0 }
    private var held: Double { store.binanceAccount?.balances.first { $0.asset == asset }?.free ?? 0 }
    private var value: Double { Double(amount).flatMap { $0.isFinite ? $0 : nil } ?? 0 }

    var body: some View {
        SheetChrome(title: "Binance", subtitle: store.binanceAccount.map { $0.canTrade ? "Spot trading on" : "Read-only key" } ?? "Loading") {
            HStack(alignment: .firstTextBaseline) {
                Text(MoneyFmt.usd(balances.reduce(0) { $0 + usd($1) }, digits: 2)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text("on Binance").foregroundStyle(Theme.muted)
            }
            if let e = store.binanceError { Text(e).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
            VStack(spacing: 0) {
                ForEach(balances.prefix(8)) { b in
                    HStack(spacing: 10) {
                        MarketLogo(key: TradeData.logo(b.asset), name: b.asset, size: 26)
                        Text(b.asset).font(.system(size: 14, weight: .medium))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Binance.Balance.fmt(b.total)).font(.system(size: 13.5)).monospacedDigit()
                            Text(MoneyFmt.usd(usd(b), digits: 2)).font(.system(size: 12)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 8)
                }
                if balances.isEmpty && store.binanceAccount != nil { EmptyNote(text: "No balances on this Binance account.") }
            }
            if store.binanceAccount?.canTrade == true {
                SectionLabel(text: "Trade on Binance") { EmptyView() }
                Segmented(options: [("buy", "Buy"), ("sell", "Sell")], selection: $side)
                HStack(spacing: 10) {
                    FormField(label: "Coin") {
                        MenuField(selection: $asset, options: ["BTC", "ETH", "SOL", "BNB", "XRP", "DOGE"], title: { $0 }, logo: { $0.lowercased() })
                    }
                    FormField(label: side == "buy" ? "Spend (USDT)" : "Sell (\(asset))",
                              trailing: side == "buy" ? "\(Binance.Balance.fmt(usdt)) USDT" : "\(Binance.Balance.fmt(held)) \(asset)") {
                        AmountTextField(text: $amount)
                    }
                }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
            }
            if !orders.isEmpty {
                SectionLabel(text: "Open orders") { EmptyView() }
                ForEach(orders) { o in
                    HStack {
                        Text("\(o.side.capitalized) \(Binance.Balance.fmt(o.qty)) \(o.symbol)").font(.system(size: 13.5))
                        Spacer()
                        Button("Cancel") { Task { try? await Binance.saved?.cancel(symbol: o.symbol, orderId: o.orderId); await load() } }
                            .buttonStyle(OutlineButton())
                    }
                }
            }
            Button("Disconnect Binance", role: .destructive) { store.disconnectBinance(); dismiss(); model.toast("Binance disconnected") }
                .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red).padding(.top, 4)
        } foot: {
            if store.binanceAccount?.canTrade == true {
                Button { Task { await review() } } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text("\(side == "buy" ? "Buy" : "Sell") \(asset)") }
                }
                .buttonStyle(WideButton())
                .disabled(busy || value <= 0 || (side == "buy" ? value > usdt : value > held))
            }
        }
        .task { await load() }
    }

    private func load() async {
        async let p = try? Binance.prices()
        await store.refreshBinance()
        prices = await p ?? prices
        orders = (try? await Binance.saved?.openOrders()) ?? []
    }

    /// Opens the review sheet for the order. Nothing is sent until Approve, and then Face ID / Touch ID, pass.
    private func review() async {
        guard value > 0, let b = Binance.saved else { return }
        busy = true; error = nil
        defer { busy = false }
        let buy = side == "buy", coin = asset, symbol = asset + "USDT", qty = value
        guard let px = (try? await Binance.prices())?[symbol], px > 0 else {
            error = "Couldn't get the \(coin) price from Binance. Try again."; return
        }
        let usd = buy ? qty : qty * px
        let policy = WalletsViewModel.shared.service.policy
        let verdict = policy.evaluate(usd: usd, payee: nil, origin: .user)
        if verdict.decision == .block { error = verdict.blocks.first ?? "Blocked by your spending policy."; return }
        var lines: [[String]] = [["Pair", "\(coin)/USDT"], ["Order", buy ? "Market buy" : "Market sell"]]
        if buy {
            lines += [["You spend", "\(Binance.Balance.fmt(qty)) USDT"], ["You get, about", "\(Binance.Balance.fmt(qty / px)) \(coin)"]]
        } else {
            lines += [["You sell", "\(Binance.Balance.fmt(qty)) \(coin)"], ["You get, about", "\(Binance.Balance.fmt(usd)) USDT"]]
        }
        lines += [["Price, about", MoneyFmt.usd(px, digits: px < 1 ? 4 : 2)], ["Fee, up to 0.1%", "about " + MoneyFmt.usd(usd * 0.001, digits: 2)],
                  ["Account", "Your Binance account"]]
        let title = "\(buy ? "Buy" : "Sell") \(coin) on Binance"
        let limit = policy.limit
        let note = BinanceOrder.Note()
        let approval = Approval(
            kind: "Binance", title: title, lines: lines,
            checks: ["Requested by you in this app", "Spot order on your own Binance account", "Withdrawals are never used"]
                + verdict.passed.filter { $0.hasPrefix("Within daily limit") },
            success: "Order sent to Binance",
            warnings: verdict.warnings + ["Market orders fill at the best price available, which can differ from the price shown."]
        ) { @Sendable () async throws -> String in
            // The review sheet only prompts for Face ID / Touch ID itself when there is no `perform`, so the order asks here.
            try await BinanceOrder.confirm(title)
            let fill: Binance.Fill
            do { fill = try await b.market(symbol: symbol, buy: buy, quote: buy ? qty : nil, qty: buy ? nil : qty) }
            catch { throw BinanceOrder.Failure(message: BinanceOrder.plain(error.localizedDescription)) }
            // What really filled counts toward the daily limit; with no fill reported, the estimate does.
            limit.record(usd: Decimal(fill.quoteSpent > 0 ? fill.quoteSpent : usd))
            note.text = fill.filledQty > 0
                ? "\(buy ? "Bought" : "Sold") \(Binance.Balance.fmt(fill.filledQty)) \(coin) for \(Binance.Balance.fmt(fill.quoteSpent)) USDT"
                : "Order sent to Binance, status \(fill.status.lowercased())"
            // A result line, not a bare order number: the review sheet shows it whole under the tick.
            return note.text
        }
        ask(approval) { model.toast(note.text.isEmpty ? "Order sent to Binance" : note.text) }
    }
}

/// A Binance order's helpers that run outside the view: the Face ID / Touch ID gate and plain error text.
enum BinanceOrder {
    /// What the order did, written once by the order and read by the toast after the review sheet closes.
    final class Note: @unchecked Sendable { var text = "" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Face ID, Touch ID or the device password. Fails closed: no passcode or no confirmation, no order.
    static func confirm(_ reason: String) async throws {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw Failure(message: "Set a passcode on \(Device.here) to place orders.")
        }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        guard ok else { throw Failure(message: "Not confirmed, so no order was placed.") }
    }

    /// Binance's filter messages in words people can act on.
    static func plain(_ m: String) -> String {
        let l = m.lowercased()
        if l.contains("market_lot_size") { return "That amount isn't allowed for a market order on this coin. Try a different amount." }
        if l.contains("lot_size") || l.contains("lot size") { return "That amount is too small or has too many decimals for this coin. Try a round amount." }
        if l.contains("notional") { return "The order is below Binance's minimum for this pair, usually $5." }
        if l.contains("filter failure") { return "Binance's trading rules don't allow this order. Try a different amount." }
        return m
    }
}

extension Binance.Balance {
    static func fmt(_ v: Double) -> String { v >= 100 ? v.formatted(.number.precision(.fractionLength(0...2))) : v.formatted(.number.precision(.significantDigits(1...6))) }
}

// MARK: MCP

/// Add a remote MCP server by its URL (Streamable HTTP), with an access token if it needs one.
struct MCPAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    private var store: ConnectorStore { .shared }

    var body: some View {
        SheetChrome(title: "Add an MCP server", subtitle: "Tools you can run") {
            FormField(label: "Server URL") {
                TextField("https://example.com/mcp", text: $url).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .modifier(FieldBox())
            }
            FormField(label: "Access token", trailing: "Optional") {
                SecureField("Only if the server asks for one", text: $token).textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .modifier(FieldBox())
            }
            NoteBox(symbol: "info.circle", text: "Remote servers only (an https address). Hermit lists the server's tools and you run them yourself. Coming soon: Hermit using them in chat.")
            if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true) }
        } foot: {
            Button {
                Task {
                    busy = true; error = nil
                    do {
                        let s = try await store.addServer(url: url, token: token)
                        dismiss(); model.toast("\(s.name) added, \(store.tools[s.id]?.count ?? 0) tools")
                    } catch { self.error = error.localizedDescription }
                    busy = false
                }
            } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Connecting" : "Add server") }
            }
            .buttonStyle(WideButton()).disabled(url.count < 10 || busy)
        }
    }
}

/// One server's tools. Tap a tool to fill in its inputs and run it.
struct MCPServerSheet: View {
    let server: ConnectorStore.MCPServer
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var tool: MCPTool?
    @State private var error: String?
    private var store: ConnectorStore { .shared }

    var body: some View {
        SheetChrome(title: server.name, subtitle: URL(string: server.url)?.host() ?? server.url, onBack: tool == nil ? nil : { withAnimation(.smooth) { tool = nil } }) {
            if let tool {
                MCPToolRunner(server: server, tool: tool)
            } else {
                let list = store.tools[server.id] ?? []
                if list.isEmpty && error == nil { MarketStatus(kind: .loading("Loading tools")) }
                if let error { Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.red) }
                ForEach(list) { t in
                    Button { withAnimation(.smooth) { tool = t } } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 26, height: 26)
                                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.system(size: 13.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                                if let d = t.description { Text(d).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint).padding(.top, 6)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Remove server", role: .destructive) { store.removeServer(server); dismiss(); model.toast("\(server.name) removed") }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red).padding(.top, 6)
            }
        }
        .task { if store.tools[server.id] == nil { do { try await store.loadTools(server) } catch { self.error = error.localizedDescription } } }
    }
}

/// Inputs for one tool (one field per top-level parameter), Run, and the result.
struct MCPToolRunner: View {
    let server: ConnectorStore.MCPServer
    let tool: MCPTool
    @State private var values: [String: String] = [:]
    @State private var output: String?
    @State private var failed = false
    @State private var busy = false
    private var store: ConnectorStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tool.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
            if let d = tool.description { Text(d).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            ForEach(tool.params, id: \.name) { p in
                FormField(label: p.name + (p.required ? "" : " (optional)"), trailing: p.type) {
                    TextField(p.description ?? "", text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 13)).autocorrectionDisabled().modifier(FieldBox())
                }
            }
            Button {
                Task { await run() }
            } label: {
                HStack(spacing: 6) { if busy { ProgressView().controlSize(.small).tint(.white) }; Text(busy ? "Running" : "Run") }
            }
            .buttonStyle(WideButton())
            .disabled(busy || tool.params.contains { $0.required && (values[$0.name] ?? "").isEmpty })
            if let output {
                ScrollView(.horizontal) {
                    Text(output).font(.system(size: 12, design: .monospaced)).foregroundStyle(failed ? Theme.red : Theme.text)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 600, alignment: .leading)
                }
                .padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func run() async {
        guard let c = store.client(server) else { return }
        busy = true; defer { busy = false }
        var args: [String: Any] = [:]
        for p in tool.params {
            guard let v = values[p.name], !v.isEmpty else { continue }
            switch p.type {
            case "number": args[p.name] = Double(v) ?? v
            case "integer": args[p.name] = Int(v) ?? v
            case "boolean": args[p.name] = ["true", "yes", "1"].contains(v.lowercased())
            case "array", "object": args[p.name] = (try? JSONSerialization.jsonObject(with: Data(v.utf8))) ?? v
            default: args[p.name] = v
            }
        }
        do {
            let r = try await c.call(tool.name, arguments: args)
            output = String(r.text.prefix(8000)); failed = r.isError
        } catch { output = error.localizedDescription; failed = true }
    }
}
