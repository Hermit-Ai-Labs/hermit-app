import SwiftUI
import HermitCore

/// Sheet chrome shared by the three pages: header with a close button, a body, a footer.
/// A dialog on the Mac, a bottom sheet with a grabber on iPhone.
struct PaySheet<Header: View, Content: View, Foot: View>: View {
    var width: CGFloat = 440
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var foot: () -> Foot
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                header().frame(maxWidth: .infinity, alignment: .leading)
                PayIconButton(symbol: "xmark", label: "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 22).padding(.trailing, 14).padding(.top, 16).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) { foot() }
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 22)
        }
        .background(Theme.bg)
        #if os(macOS)
        .frame(width: width)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
        #endif
    }
}

struct PaySheetTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 18, weight: .semibold)).lineLimit(1) }
}

extension PaySheet where Header == PaySheetTitle {
    init(title: String, width: CGFloat = 440, @ViewBuilder content: @escaping () -> Content, @ViewBuilder foot: @escaping () -> Foot) {
        self.init(width: width, header: { PaySheetTitle(text: title) }, content: content, foot: foot)
    }
}

/// A scheduled payment: change the amount, pause or resume, pay now (approval) or cancel it.
struct PayScheduleSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let item: PayScheduleItem
    @State var amount = ""
    private var store: PaymentsStore { .shared }

    var body: some View {
        let paused = store.paused.contains(item.id)
        PaySheet(title: item.to) {
            HStack(spacing: 12) {
                PayLogo(name: item.to, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PayFormat.amount(Double(amount) ?? item.amt)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(paused ? "Paused" : item.live ? "Paying per call" : "Next payment \(item.when.lowercased())")
                        .font(.system(size: 12.5)).foregroundStyle(paused ? Theme.amber : Theme.muted)
                }
            }
            .padding(.bottom, 4)
            PayLines(lines: [("For", item.what), ("Next", item.when), ("Paid with", item.rail), ("Status", paused ? "Paused" : "Scheduled")])
            PayField(label: "Amount") {
                HStack {
                    Text("$").foregroundStyle(Theme.faint)
                    TextField("0", text: $amount).textFieldStyle(.plain).monospacedDigit()
                        .onSubmit(saveAmount)
                    if (Double(amount) ?? item.amt) != item.amt {
                        Button("Save", action: saveAmount).buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                            .transition(.opacity)
                    }
                }
                .font(.system(size: 14))
                .payInputBox()
            }
            Button("Cancel this payment") {
                withAnimation(.snappy) { store.schedule.removeAll { $0.id == item.id } }
                dismiss(); model.toast("Payment cancelled")
            }
            .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red)
            .padding(.vertical, 4)
        } foot: {
            Button(paused ? "Resume" : "Pause") {
                store.togglePause(item.id)
                model.toast(paused ? "Resumed" : "Paused")
            }
            .buttonStyle(PayWideButton(kind: .plain)).frame(width: 120)
            Button("Pay now") {
                let amt = Double(amount) ?? item.amt
                dismiss()
                PayApprovalHook.shared.request(Approval(
                    kind: "Payment", title: "Pay \(item.to) now",
                    lines: [["For", item.what], ["Amount", PayFormat.amount(amt)], ["Route", item.rail]],
                    checks: PayChecks.base(), success: "Paid \(item.to)",
                    receipt: .receipt(title: "Paid \(item.to)", rows: [["Amount", PayFormat.amount(amt)], ["Route", item.rail], ["Fee", "$0.01"]])
                ), model: model, afterSheet: true) { store.spend(amt) }
            }
            .buttonStyle(PayWideButton(kind: .black))
        }
        .animation(.snappy, value: amount)
        .onAppear { amount = item.amt < 1 ? String(format: "%.2f", item.amt) : String(Int(item.amt)) }
    }

    private func saveAmount() {
        guard let v = Double(amount), v > 0, let i = store.schedule.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.snappy) { store.schedule[i].amt = v }
        model.toast("Amount updated")
    }
}

/// "Explore more services" with a search button, opening a searchable list. Picking an item asks Hermit.
struct PayExploreMore: View {
    let label: String
    let items: [PayMoreItem]
    @State var open = false

    var body: some View {
        HStack(spacing: 8) {
            Button { open = true } label: { Text("Explore more \(label)").frame(maxWidth: .infinity) }
                .buttonStyle(PayExploreButton())
            Button { open = true } label: { Image(systemName: "magnifyingglass").frame(width: 18) }
                .buttonStyle(PayExploreButton())
                .accessibilityLabel("Search \(label)")
        }
        .sheet(isPresented: $open) { PayExploreSheet(label: label, items: items) }
    }
}

private struct PayExploreButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).frame(height: 42)
            .background(configuration.isPressed ? Theme.hover : Theme.bg, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct PayExploreSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    let label: String
    let items: [PayMoreItem]
    @State var q = ""
    @FocusState var focused: Bool

    var body: some View {
        let list = items.filter { q.isEmpty || "\($0.name) \($0.sub) \($0.tag ?? "")".localizedCaseInsensitiveContains(q) }
        PaySheet(width: 520) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint).font(.system(size: 13))
                TextField("Search \(label)", text: $q).textFieldStyle(.plain).focused($focused)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12).frame(height: 38)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        } content: {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                        Button {
                            dismiss(); model.send("Tell me about \(item.name)")
                        } label: {
                            HStack(spacing: 12) {
                                PayLogo(name: item.logo, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                    Text(item.sub).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let tag = item.tag { Text(tag).font(.system(size: 12)).foregroundStyle(Theme.faint) }
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(PayRowStyle())
                        .payLine(i > 0)
                    }
                    if list.isEmpty {
                        Text("No results").foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.horizontal, -10)
            .frame(height: SnapshotMode.active ? nil : 420)
        } foot: { EmptyView() }
        .onAppear { focused = true }
    }
}
