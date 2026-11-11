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
    /// The app's one model, made once. SwiftUI rebuilds RootView whenever the scene updates, and `RootView()` used to
    /// create a fresh AppModel (and a fresh on-device engine that loaded the AI model) on every rebuild.
    @MainActor private static let appModel = AppModel()

    private var rootView: RootView {
        #if DEBUG && os(macOS)
        RootView(model: MacTour.model)
        #else
        RootView(model: Self.appModel)
        #endif
    }
    #if os(iOS)
    @UIApplicationDelegateAdaptor(HermitAppDelegate.self) private var appDelegate
    #endif
    init() {
        HermitFonts.register()
        // Before launch finishes, so tapping an automation's notification that opened the app reaches its chat.
        AutomationNotificationHandler.install()
        #if DEBUG && os(macOS)
        MacTour.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(.light)
        }
        .commands { HermitCommands() }
        #if os(macOS)
        .defaultSize(width: 1320, height: 822)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        #endif
    }
}
