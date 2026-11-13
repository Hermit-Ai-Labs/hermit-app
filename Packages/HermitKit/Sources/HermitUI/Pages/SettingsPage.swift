import SwiftUI
import LocalAuthentication
import HermitCore
import HermitWallet

/// Settings (demo: Settings.jsx): Profile, Safety, Memory (hermit.md), Models (on-device), Home.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "profile"
    /// The wallet's real daily limit (SpendLimit, the one every send and swap is checked against), in whole dollars.
    @State private var daily = 500
    @AppStorage("home.balanceOn") private var showBalance = false
    @AppStorage("home.showMarkets") private var showMarkets = true
    @AppStorage("home.showToday") private var showToday = true

    var body: some View {
        Page(title: "Settings", tabs: [("profile", "Profile"), ("safety", "Safety"), ("memory", "Memory"), ("models", "Models"), ("cloud", "Cloud"), ("sites", "Sites"), ("home", "Home")], tab: $tab) { t in
            switch t {
            case "profile": ProfileSettings()
            case "safety": safety
            case "memory": MemoryEditor()
            case "models":
                VStack(alignment: .leading, spacing: 10) {
                    Text("Hermit runs on this device. Nothing you type leaves it.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    ModelSheet(embedded: true)
                }
            case "cloud": CloudSettings()
            case "sites": ConnectedSitesSettings()
            case "home": home
            default: ProfileSettings()
            }
        }
        .onAppear {
            if let r = model.tabRequest, ["profile", "safety", "memory", "models", "cloud", "sites", "home"].contains(r) { tab = r; model.tabRequest = nil }
        }
    }

    private var safety: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Daily limit", sub: "Hermit stops spending for the day at this amount") {
                ValueMenu(selection: Binding(get: { daily }, set: { setDaily($0) }), options: dailyOptions) { MoneyFmt.usd(Double($0)) }
            }
            Hairline()
            SettingRow(title: "Hazard scan, injection shield, approval limits", sub: "Checks every transaction before you approve") {
                Text("Always on").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
            }
            Hairline()
            SettingRow(title: "Approve with \(Device.bio)", sub: "Your keys never leave \(Device.here)") {
                Text("Always on").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
            }
            NoteBox(symbol: "checkmark.shield", text: "Every send, swap and trade asks for \(Device.bio). Hermit stops at \(MoneyFmt.usd(Double(daily))) a day, counting every move it can price.")
                .padding(.top, 18)
                .contentTransition(.opacity)
                .animation(.smooth, value: daily)
        }
        .onAppear { daily = Self.dollars(spendLimit.dailyLimitUSD) }
    }

    private var spendLimit: SpendLimit { WalletsViewModel.shared.service.spendLimit }

    /// The menu's amounts, with the saved limit among them even when it isn't one of the usual ones.
    private var dailyOptions: [Int] { Array(Set([100, 250, 500, 1000, 2000, 5000, 10000, daily])).sorted() }

    private static func dollars(_ d: Decimal) -> Int { NSDecimalNumber(decimal: d).intValue }

    /// Lowering the limit is saved at once. Raising it needs Face ID, Touch ID or the device password first, and fails
    /// closed: no passcode or no confirmation, the limit stays where it was.
    private func setDaily(_ v: Int) {
        let old = daily
        guard v != old else { return }
        guard v > old else { applyDaily(v); return }
        Task { @MainActor in
            let ctx = LAContext()
            var err: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
                model.toast("Set a passcode on \(Device.here) to raise the limit", kind: .error); return
            }
            let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Raise your daily limit to \(MoneyFmt.usd(Double(v)))")) ?? false
            if ok { applyDaily(v) } else { model.toast("Not confirmed, so the limit stays \(MoneyFmt.usd(Double(old)))", kind: .error) }
        }
    }

    private func applyDaily(_ v: Int) {
        spendLimit.dailyLimitUSD = Decimal(v)
        withAnimation(.smooth) { daily = v }
        model.toast("Daily limit \(MoneyFmt.usd(Double(v)))", kind: .success)
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Balance", sub: "Your wallets' total, on the home screen") {
                Toggle("Balance", isOn: $showBalance).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
            Hairline()
            SettingRow(title: "Markets", sub: "Live prices on Home") {
                Toggle("Markets", isOn: $showMarkets).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
            if showMarkets {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Card style").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                    MarketStylePicker()
                }
                .padding(.bottom, 14)
                .transition(.opacity)
            }
            Hairline()
            SettingRow(title: "Today", sub: "To-dos and events for today") {
                Toggle("Today", isOn: $showToday).labelsHidden().toggleStyle(.switch).tint(Theme.text)
            }
        }
        .onChange(of: showBalance) { _, v in model.toast(v ? "Balance shown on Home" : "Balance hidden on Home") }
        .onChange(of: showMarkets) { _, v in model.toast(v ? "Markets shown on Home" : "Markets hidden on Home") }
        .onChange(of: showToday) { _, v in model.toast(v ? "Today shown on Home" : "Today hidden on Home") }
    }
}

/// What Hermit calls you. There is no account: the name lives on this device.
struct ProfileSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var dirty: Bool { !trimmed.isEmpty && trimmed != model.user }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "What Hermit calls you", sub: "Used in greetings and in chat") {
                HStack(spacing: 8) {
                    TextField(text: $draft, prompt: Text("Your name").foregroundStyle(Theme.hint)) { Text("Name") }
                        .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                        .focused($focused).autocorrectionDisabled()
                        .padding(.horizontal, 12).frame(minWidth: 200, maxWidth: .infinity).frame(height: 36)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? Theme.faint : Theme.border))
                        .onSubmit(save)
                    Button("Save", action: save).buttonStyle(BlackButton()).disabled(!dirty)
                }
            }
            Hairline()
            SettingRow(title: "Account", sub: "None needed. Your chats, memory and keys stay on this device") {
                Text("On this device").font(.system(size: 12.5)).foregroundStyle(Theme.hint)
            }
            Hairline()
            SettingRow(title: "Welcome screen", sub: "See the first screen again. Only your name is asked again; wallets and chats stay") {
                Button("Show") { withAnimation(.smooth(duration: 0.5)) { model.user = "" } }.buttonStyle(BlackButton())
            }
            Hairline()
            SettingRow(title: "Terms and privacy", sub: "Your keys, your approvals. Hermit charges no fees and collects nothing from the app") {
                HStack(spacing: 8) {
                    Button("Terms") { openURL(URL(string: "https://hermit.my/terms")!) }.buttonStyle(BlackButton())
                    Button("Privacy") { openURL(URL(string: "https://hermit.my/privacy")!) }.buttonStyle(BlackButton())
                }
            }
        }
        .onAppear { draft = model.user }
    }

    private func save() {
        guard dirty else { return }
        model.user = String(trimmed.prefix(40))
        focused = false
        model.toast("Hermit will call you \(model.user)")
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        // Side by side when the label keeps a readable width; on a narrow iPhone the control drops below it.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                label.frame(minWidth: 170, alignment: .leading)
                Spacer(minLength: 10)
                trailing().fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                label
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 13)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).uiFont(14)
            if let sub { Text(sub).uiFont(12.5, relativeTo: .footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
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
