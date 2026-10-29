import SwiftUI

/// Expandable opportunity row: tap for public stats and history, then act on it or ask Hermit.
struct EarnOppRow<Sub: View>: View {
    let logo: String
    let title: String
    var isNew = false
    let metric: String
    let detail: EarnData.Detail?
    let action: String
    @ViewBuilder var sub: () -> Sub
    let onAction: () -> Void

    @State private var open = false
    @State private var asking = false
    @State private var width: CGFloat = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.32)) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    LogoMark(logo, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                            if isNew {
                                Text("New").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Color(hex: 0xF1ECFA), in: Capsule())
                            }
                        }
                        sub().font(.system(size: 12.5)).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(metric).font(.system(size: 14, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(TradeRowButton())
            .accessibilityValue(open ? "Expanded" : "Collapsed")

            if open, let d = detail {
                details(d)
                    .padding(.leading, width >= 600 ? 44 : 0)
                    .padding(.top, 2).padding(.bottom, 18)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .clipped()
        .tradeWidth($width)
        .sheet(isPresented: $asking) {
            if let d = detail {
                TradeAskSheet(q: "Is \(title) a good fit for me?",
                              a: "\(title): \(d.note) 90-day average \(d.avg), worst drawdown \(d.dd.isEmpty ? "none recorded" : d.dd). With $8,200 idle, I would keep it under 20% of your stablecoins.")
            }
        }
    }

    private func details(_ d: EarnData.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(d.histLabel).foregroundStyle(Theme.muted)
                Spacer()
                Text("Avg \(d.avg)").monospacedDigit()
            }
            .font(.system(size: 12.5)).padding(.bottom, 6)
            LineChart(values: d.series, color: Theme.text).frame(height: 80)
            TradeKV(pairs: d.pairs).padding(.top, 14)
            Text(d.note).font(.system(size: 12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            HStack(spacing: 8) {
                Button(action, action: onAction).buttonStyle(TradeSmallButton(kind: .primary))
                Button { asking = true } label: { Label("Ask", systemImage: "sparkles") }
                    .buttonStyle(TradeSmallButton(kind: .brand))
            }
            .padding(.top, 14)
            Text("Illustrative figures for the demo").font(.system(size: 12)).foregroundStyle(Theme.faint).padding(.top, 10)
        }
    }
}
