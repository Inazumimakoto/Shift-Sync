import FirebaseMessaging
import UIKit
import UserNotifications

@MainActor
final class ShiftSyncAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AnnouncementService.shared.configure()
        if AnnouncementService.shared.isConfigured {
            Messaging.messaging().delegate = self
        }
        Task { await AnnouncementService.shared.refresh() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AnnouncementService.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AnnouncementService.shared.didFailToRegisterForRemoteNotifications()
    }

    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in
            AnnouncementService.shared.didReceiveRegistrationToken(fcmToken)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route: AppRoute?
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           response.notification.request.trigger is UNPushNotificationTrigger {
            let content = response.notification.request.content
            route = AppAnnouncement.fromNotification(
                title: content.title,
                body: content.body,
                userInfo: content.userInfo,
                fallbackID: response.notification.request.identifier
            ).route
        } else {
            route = nil
        }

        // UIKit also updates its restoration snapshot in the completion handler.
        // The async delegate bridge can call it on a background executor even
        // after MainActor.run returns, causing a main-thread assertion on tap.
        Task { @MainActor in
            defer { completionHandler() }
            if let route {
                AppRouter.shared.open(route)
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else {
            // Preserve the existing behavior of local sync notices while the app is open.
            return []
        }
        let settings = await center.notificationSettings()
        return AnnouncementService.allowsAnnouncements(settings.authorizationStatus)
            ? [.banner, .list, .sound] : []
    }
}
