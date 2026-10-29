import SwiftUI
import HermitCore

/// Cards the agent posts under its answers. Numbers always come with a chart.
struct CardView: View {
    let card: Card
    var body: some View {
        switch card {
        case .bars(let title, let rows): BarsCard(title: title, rows: rows)
        case .receipt(let title, let rows): ReceiptCard(title: title, rows: rows)
        }
    }
}

struct BarsCard: View {
    let title: String
    let rows: [BarRow]
    @State private var grown = false

    var body: some View {
        let top = rows.map(\.value).max() ?? 1
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13.5, weight: .medium))
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(r.label).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(r.display).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hover)
                            Capsule().fill(r.highlight ? Theme.accent : Theme.text)
                                .frame(width: grown ? g.size.width * r.value / top : 0)
                                .animation(.smooth(duration: 0.7).delay(Double(i) * 0.08), value: grown)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(16).card()
        .onAppear { grown = true }
    }
}

struct ReceiptCard: View {
    let title: String
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            ForEach(rows, id: \.self) { r in
                HStack {
                    Text(r.first ?? "").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(r.last ?? "").monospacedDigit()
                }
                .font(.system(size: 13))
            }
        }
        .padding(16).card()
    }
}
