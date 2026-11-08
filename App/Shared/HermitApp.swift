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
    private var rootView: RootView {
        #if DEBUG && os(macOS)
        RootView(model: MacTour.model)
        #else
        RootView()
        #endif
    }
    #if os(iOS)
    @UIApplicationDelegateAdaptor(HermitAppDelegate.self) private var appDelegate
    #endif
    init() {
        HermitFonts.register()
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
