import SwiftUI

/// Connecting another app needs its sign-in (OAuth), which isn't built yet. The sheet says so plainly
/// instead of pretending to sign in. `onDone` is kept for callers and runs once sign-in exists.
struct ConnectAppSheet: View {
    @Environment(\.dismiss) private var dismiss
    let app: String
    let onDone: () -> Void

    var body: some View {
        SheetChrome(title: "Connect \(app)") {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    LogoMark("hermit", size: 46)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    LogoMark(app, size: 46)
                }
                Text("Connecting \(app) is coming soon").font(.system(size: 15.5, weight: .semibold)).multilineTextAlignment(.center)
                Text("Sign-in to other apps isn't built yet. When it is, you'll approve exactly what Hermit can see and do.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect") {}.buttonStyle(WideButton(kind: .accent)).comingSoon()
                Button("Close") { dismiss() }.buttonStyle(WideButton(kind: .plain)).keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }
}
