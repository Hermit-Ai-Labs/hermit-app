import SwiftUI
import HermitCore

/// Trade: your positions, the live market terminal (perps, spot, memes, predictions) and strategies.
/// Prices are real; placing orders isn't wired to an exchange yet, so those buttons are greyed out.
struct TradePage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "markets"
    static let tabs = [("markets", "Markets"), ("positions", "Positions"), ("strategies", "Strategies")]

    var body: some View {
        Page(title: "Trade", tabs: Self.tabs, tab: $tab) { t in
            switch t {
            case "markets": TradeMarkets()
            case "strategies": TradeStrategies()
            default: TradePositions()
            }
        }
        .onAppear {
            if let r = model.tabRequest, Self.tabs.contains(where: { $0.0 == r }) { tab = r; model.tabRequest = nil }
        }
    }
}

// MARK: Positions

/// No exchange is connected yet, so there is nothing to list. Each section says so instead of showing sample rows.
struct TradePositions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TradeSection(title: "Open positions", top: 0) {
                TradeEmpty(icon: "chart.line.uptrend.xyaxis", title: "No positions yet",
                           note: "Trading opens soon. Positions you open from Hermit will show here with live PnL.")
            }
            TradeSection(title: "Open orders") { MarketStatus(kind: .empty("No open orders")) }
            TradeSection(title: "History") { MarketStatus(kind: .empty("No trades yet")) }
        }
    }
}

/// Centered empty state: icon, title, one line of context.
struct TradeEmpty: View {
    let icon: String
    let title: String
    let note: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44).background(Theme.subtle, in: Circle())
            Text(title).font(.system(size: 14.5, weight: .medium))
            Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: Strategies

struct TradeStrategies: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TradeSection(title: "Running", top: 0) {
            Button { model.send("Help me plan a trading strategy") } label: {
                Label("Plan one with Hermit", systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .buttonStyle(TradeSmallButton())
        } content: {
            TradeEmpty(icon: "gearshape.2", title: "No strategies running",
                       note: "Automated strategies open together with trading. You can already plan one with Hermit in chat.")
        }
    }
}
