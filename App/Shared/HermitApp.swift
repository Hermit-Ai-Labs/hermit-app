import SwiftUI
import HermitUI

@main
struct HermitApp: App {
    init() { HermitFonts.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
        }
        .commands { HermitCommands() }
        #if os(macOS)
        .defaultSize(width: 1320, height: 822)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
    }
}
