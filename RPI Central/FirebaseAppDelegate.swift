import UIKit

#if canImport(FirebaseCore)
import FirebaseCore
#endif

final class FirebaseAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
#if canImport(FirebaseCore)
        let hasConfigFile = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
        if hasConfigFile, FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
#endif
        return true
    }
}
