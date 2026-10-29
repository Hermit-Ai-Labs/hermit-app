import SwiftUI
import HermitCore

/// Settings (demo: Settings.jsx): Safety, Memory (hermit.md), Models (on-device), Home.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "safety"
    @AppStorage("settings.askAbove") private var askAbove = 100
    @AppStorage("settings.dailyLimit") private var daily = 2000
    @AppStorage("home.showBalance") private var showBalance = true
    @AppStorage("home.showToday") private var showToday = true

    var body: some View {
        Page(title: "Settings", tabs: [("safety", "Safety"), ("memory", "Memory"), ("models", "Models"), ("home", "Home")], tab: $tab) { t in
            switch t {
            case "memory": MemoryEditor()
            case "models": ModelsList()
            case "home": home
            default: safety
            }
        }
        .onAppear {
            if let r = model.tabRequest, ["safety", "memory", "models", "home"].contains(r) { tab = r; model.tabRequest = nil }
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Ask me before spending over", sub: "Anything above this needs your approval") {
                ValueMenu(selection: $askAbove, options: [0, 50, 100, 500, 1000]) { $0 == 0 ? "Always ask" : MoneyFmt.usd(Double($0)) }
            }
            Hairline()
            SettingRow(title: "Daily limit", sub: "Hermit stops spending for the day at this amount") {
                ValueMenu(selection: $daily, options: [500, 1000, 2000, 5000, 10000]) { MoneyFmt.usd(Double($0)) }
            }
            Hairline()
            SettingRow(title: "Hazard scan, injection shield, approval limits", sub: "Checks every transaction before you approve") {
                Text("Always on").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            }
            Hairline()
            SettingRow(title: "Approve with Face ID or Touch ID", sub: "Keys never leave the Secure Enclave") {
                Text("Always on").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
            }
            NoteBox(symbol: "checkmark.shield", text: askAbove == 0
                    ? "Hermit asks before every payment, trade and deposit."
                    : "Hermit can spend up to \(MoneyFmt.usd(Double(askAbove))) at a time without asking, and never more than \(MoneyFmt.usd(Double(daily))) a day.")
                .padding(.top, 18)
                .contentTransition(.opacity)
                .animation(.smooth, value: askAbove)
        }
        .onChange(of: askAbove) { _, v in model.toast(v == 0 ? "Hermit will always ask" : "Asks above \(MoneyFmt.usd(Double(v)))") }
        .onChange(of: daily) { _, v in model.toast("Daily limit \(MoneyFmt.usd(Double(v)))") }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Balance", sub: "Money managed by the agent, on the home screen") {
                Toggle("Balance", isOn: $showBalance).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
            Hairline()
            SettingRow(title: "Today", sub: "To-dos and events for today") {
                Toggle("Today", isOn: $showToday).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
        }
        .onChange(of: showBalance) { _, v in model.toast(v ? "Balance shown on Home" : "Balance hidden on Home") }
        .onChange(of: showToday) { _, v in model.toast(v ? "Today shown on Home" : "Today hidden on Home") }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let sub { Text(sub).font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.vertical, 13)
    }
}

/// Compact native menu showing the current value.
struct ValueMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let title: (T) -> String
    var body: some View {
        Menu {
            Picker("", selection: $selection) { ForEach(options, id: \.self) { Text(title($0)).tag($0) } }
                .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(title(selection)).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
