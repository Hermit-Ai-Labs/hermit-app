import SwiftUI
import HermitUI
#if os(iOS)
import HermitModel
import UIKit

/// iPhone launch hooks: background model downloads (see ModelStore.handleBackgroundEvents).
final class HermitAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ModelStore.appDidLaunch()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        ModelStore.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}
#endif

@main
struct HermitApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(HermitAppDelegate.self) private var appDelegate
    #endif
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
