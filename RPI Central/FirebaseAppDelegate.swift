import UIKit
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

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
        return true
    }

#if canImport(FirebaseMessaging)
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationManager.setDidRegisterForRemoteNotifications(true)
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
        let socialType = (userInfo["socialType"] as? String) ?? (userInfo["type"] as? String) ?? ""
        let socialContextID = (userInfo["socialContextID"] as? String) ?? (userInfo["contextID"] as? String) ?? ""
        if socialType == "groupMessage", socialContextID == NotificationManager.activeSocialContextID {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound, .badge])
    }
}

#if canImport(FirebaseMessaging)
extension FirebaseAppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        NotificationManager.updateFCMToken(fcmToken)
    }
}
#endif
