import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// A chat the user asked to open by tapping a notification. Held until the
/// Social tab is ready, since a tap can cold-launch the app.
enum SocialDeepLink {
    static let didChangeNotification = Notification.Name("rpiCentral.socialDeepLinkDidChange")
    private(set) static var pendingContextID: String?

    static func open(contextID: String) {
        pendingContextID = contextID
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func consume() -> String? {
        defer { pendingContextID = nil }
        return pendingContextID
    }
}

final class FirebaseAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
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
        UNUserNotificationCenter.current().delegate = self
#if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = self
#endif
        NotificationManager.registerForRemoteNotificationsIfAuthorized()

        // iOS relaunches the app in the background for shared-location
        // events; the location manager must exist to receive them.
        LocationSharingManager.shared.handleLaunch()
        WatchSync.shared.activate()
        return true
    }

#if canImport(FirebaseMessaging)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationManager.setDidRegisterForRemoteNotifications(true)
        #if DEBUG
        let tokenHex = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("✅ APNs registration succeeded. Device token:", tokenHex)
        #endif
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationManager.setDidRegisterForRemoteNotifications(false)
        #if DEBUG
        print("❌ Remote notification registration failed:", error)
        #endif
    }
#endif

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if NotificationManager.shouldSuppressForegroundSocialPush(userInfo: userInfo) {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let payload = NotificationManager.socialPushPayload(from: userInfo),
           payload.type == "groupMessage",
           !payload.contextID.isEmpty {
            SocialDeepLink.open(contextID: payload.contextID)
        } else if let link = userInfo["deeplink"] as? String, let url = URL(string: link) {
            DispatchQueue.main.async {
                UIApplication.shared.open(url)
            }
        }
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
extension FirebaseAppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        NotificationManager.updateFCMToken(fcmToken)
    }
}
#endif
