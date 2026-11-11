import SwiftUI

/// Wraps cards that only the scripted demo (Scenarios) can post. They show sample prices, sample balances and
/// approvals that do nothing, so a release build never draws them: it shows a plain "Example only" card instead.
/// Debug builds and snapshot tests draw the real card.
struct DemoOnly<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private static var allowed: Bool {
        #if DEBUG
        return true
        #else
        return SnapshotMode.active
        #endif
    }

    var body: some View {
        if Self.allowed {
            content()
        } else {
            ChatCard {
                Image(systemName: "info.circle").foregroundStyle(Theme.muted).font(.system(size: 14))
                Text("Example only").font(.system(size: 13.5, weight: .medium))
            } content: {
                Text("This card shows sample data and isn't connected to your accounts.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
        }
    }
}
