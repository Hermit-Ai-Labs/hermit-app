import SwiftUI

/// New chat: the crab, the greeting, wallet actions, the chat box, then today's cards.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image.hermit("hermit-hero").resizable().interpolation(.high).scaledToFit()
                    .frame(height: 150).padding(.top, 64)
                    .scaleEffect(appeared ? 1 : 0.94).opacity(appeared ? 1 : 0)
                Text("\(greeting), \(model.user)").font(.serif(40)).foregroundStyle(Theme.text)
                    .padding(.top, 14)
                HStack(spacing: 22) {
                    walletAction("Send", "arrow.up.right")
                    walletAction("Swap", "arrow.left.arrow.right")
                    walletAction("Receive", "arrow.down.left")
                    walletAction("Buy", "creditcard")
                }
                .padding(.top, 22)
                Composer().padding(.top, 26)
                HStack(spacing: 8) {
                    ForEach(["Trade the news", "DeFi ideas", "Build a bot", "Pay alice.eth 200 USDC on Friday"], id: \.self) { s in
                        Button(s) { model.send(s) }.buttonStyle(ChipStyle())
                    }
                }
                .padding(.top, 14)
                HStack(alignment: .top, spacing: 14) {
                    ManagedCard()
                    TodayCard()
                }
                .padding(.top, 48).padding(.bottom, 40)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.never)
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25)) { appeared = true } }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private func walletAction(_ title: String, _ symbol: String) -> some View {
        Button {} label: {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40).background(Theme.hover, in: Circle())
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
        .buttonStyle(PressStyle())
    }
}

struct ManagedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Managed by agent").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            HStack(spacing: 18) {
                Donut(parts: [(0.46, Theme.text), (0.28, Theme.accent), (0.18, Color(hex: 0x9C82D4)), (0.08, Color(hex: 0xE4DDF2))])
                    .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 3) {
                    Text("$48,320").font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("+2.6% this week").font(.system(size: 12.5)).foregroundStyle(Theme.green)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct TodayCard: View {
    @State private var done: Set<String> = []
    let items = [("Approve ETH DCA", "09:00"), ("Claim HYPE rewards", ""), ("Standup with dev team", "14:30"), ("Review arb bot PnL", "11:00")]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            ForEach(items, id: \.0) { item in
                Button {
                    withAnimation(.snappy) { if done.contains(item.0) { done.remove(item.0) } else { done.insert(item.0) } }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: done.contains(item.0) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done.contains(item.0) ? Theme.accent : Theme.faint).font(.system(size: 13))
                        Text(item.0).font(.system(size: 13)).strikethrough(done.contains(item.0), color: Theme.faint)
                            .foregroundStyle(done.contains(item.0) ? Theme.faint : Theme.text)
                        Spacer()
                        Text(item.1).font(.system(size: 12)).foregroundStyle(Theme.faint).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct Donut: View {
    let parts: [(Double, Color)]
    var body: some View {
        ZStack {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let start = parts.prefix(i).reduce(0) { $0 + $1.0 }
                Circle().trim(from: start + 0.006, to: start + part.0 - 0.006)
                    .stroke(part.1, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

extension View {
    func card() -> some View {
        background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
