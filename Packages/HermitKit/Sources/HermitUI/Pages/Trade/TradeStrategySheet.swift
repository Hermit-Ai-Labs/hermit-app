import SwiftUI

/// Detail for a running strategy (Trade and Earn): stats, how it works, recent trades, Pause, and the chat or project it came from.
struct TradeStrategySheet: View {
    let st: TradeData.Strategy
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private var store: TradeEarnStore { .shared }

    var body: some View {
        let running = !store.paused.contains(st.id)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                LogoMark(st.sym, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(st.source).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    Text(st.name).font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                TradeSheetClose { dismiss() }
            }
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TradeKV(pairs: [("PnL 30d", st.pnl.tradeUSD), ("Capital", "$" + st.capital.tradeGrouped()), ("Win rate", st.win),
                                    ("Status", running ? "Running" : "Paused")],
                            colors: ["PnL 30d": st.pnl >= 0 ? Theme.green : Theme.red, "Status": running ? Theme.text : Theme.faint])
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How it works").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        TradeFlowDiagram(steps: st.steps)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recent").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.bottom, 4)
                        ForEach(Array(st.trades.enumerated()), id: \.offset) { i, t in
                            VStack(spacing: 0) {
                                if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.0).font(.system(size: 14)).lineLimit(1)
                                        Text(t.1).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    if !t.2.isEmpty {
                                        Text(t.2).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                            .foregroundStyle(t.2.hasPrefix("+") ? Theme.green : Theme.red)
                                    }
                                }
                                .padding(.vertical, 9)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            HStack(spacing: 10) {
                Button(running ? "Pause" : "Resume") {
                    withAnimation(.snappy) { if running { store.paused.insert(st.id) } else { store.paused.remove(st.id) } }
                    model.toast(running ? "Strategy paused" : "Strategy resumed")
                }
                .buttonStyle(SheetButton(primary: false))
                Button(st.fromChat ? "Open chat" : "Open project") {
                    dismiss()
                    if st.fromChat { model.send("How is my \(st.name) strategy doing?") } else { model.open(.projects) }
                }
                .buttonStyle(TradeSheetPrimary())
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .tradeSheet(width: 560, height: 560)
    }
}

/// Black primary sheet button (purple stays for Approve).
struct TradeSheetPrimary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .background(Theme.text.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 11))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
