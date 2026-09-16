import Combine
import FirebaseCore
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

/// Firebase announcements follow the app's existing OS notification authorization.
@MainActor
final class AnnouncementService: ObservableObject {
    static let shared = AnnouncementService()

    @Published private(set) var statusMessage: String?
    @Published private(set) var isConfigured = false

    #if DEBUG
    static let topic = "shiftsync-announcements-debug"
    private static let otherTopic = "shiftsync-announcements-prod"
    #else
    static let topic = "shiftsync-announcements-prod"
    private static let otherTopic = "shiftsync-announcements-debug"
    #endif

    private static let registrationExistsKey = "announcements.registrationExists.v1"

    private let defaults: UserDefaults
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var registrationToken: String?
    private var hasRequestedRemoteRegistration = false
    private var isReconciling = false
    private var needsAnotherPass = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The previous independent opt-in is superseded by OS notification settings.
        defaults.removeObject(forKey: "announcements.enabled.v1")
        defaults.removeObject(forKey: "announcements.pendingTopicUpdate.v1")
    }

    func configure() {
        guard !isConfigured else { return }

        if FirebaseApp.app() == nil {
            guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
                  let options = FirebaseOptions(contentsOfFile: path),
                  !options.googleAppID.isEmpty,
                  !options.gcmSenderID.isEmpty,
                  let projectID = options.projectID, !projectID.isEmpty,
                  let apiKey = options.apiKey, !apiKey.isEmpty,
                  options.bundleID == Bundle.main.bundleIdentifier else {
                statusMessage = "お知らせの配信設定がまだ完了していません。"
                return
            }
            FirebaseApp.configure(options: options)
        }

        isConfigured = true
        // Info.plist also disables auto-init to cover the period before this call.
        Messaging.messaging().isAutoInitEnabled = false
        statusMessage = "通知の設定を確認しています…"
    }

    /// Refresh on foreground entry as well as APNs/FCM registration changes.
    func refresh() async {
        configure()
        guard isConfigured else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        let wantsSubscription = canPresentNotifications
        Messaging.messaging().isAutoInitEnabled = wantsSubscription

        if wantsSubscription {
            // Retain this until server-side cleanup succeeds, including across app restarts.
            defaults.set(true, forKey: Self.registrationExistsKey)
            if !hasRequestedRemoteRegistration {
                hasRequestedRemoteRegistration = true
                UIApplication.shared.registerForRemoteNotifications()
            }
            guard Messaging.messaging().apnsToken != nil else {
                statusMessage = "通知を受け取る準備をしています…"
                return
            }
        }

        await reconcileSubscription()
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        guard isConfigured else { return }
        Messaging.messaging().apnsToken = deviceToken
        Task { await refresh() }
    }

    func didFailToRegisterForRemoteNotifications() {
        hasRequestedRemoteRegistration = false
        guard canPresentNotifications else { return }
        statusMessage = "プッシュ通知に登録できませんでした。次回アプリを開いたときに再試行します。"
    }

    func didReceiveRegistrationToken(_ token: String?) {
        guard let token, token != registrationToken else { return }
        registrationToken = token
        defaults.set(true, forKey: Self.registrationExistsKey)
        Task { await refresh() }
    }

    private var canPresentNotifications: Bool {
        Self.allowsAnnouncements(authorizationStatus)
    }

    nonisolated static func allowsAnnouncements(_ authorizationStatus: UNAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func reconcileSubscription() async {
        guard !isReconciling else {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherPass = false
            let shouldSubscribe = canPresentNotifications
            let messaging = Messaging.messaging()
            messaging.isAutoInitEnabled = shouldSubscribe

            do {
                if shouldSubscribe {
                    guard messaging.apnsToken != nil else { return }
                    // An older in-flight deletion may have cleared this after refresh()
                    // observed restored OS permission. Mark the registration attempt too.
                    defaults.set(true, forKey: Self.registrationExistsKey)
                    statusMessage = "お知らせの配信を登録しています…"
                    // Firebase 12.19.2's replacement register()/unregister() APIs
                    // reject the default token mode unless the FID feature flag is on.
                    // Keep the token APIs and delegate together until that migration.
                    let token = try await messaging.token()
                    registrationToken = token
                    guard canPresentNotifications else {
                        needsAnotherPass = true
                        continue
                    }
                    // Switching between a debug and release build must not retain both topics.
                    try await messaging.unsubscribe(fromTopic: Self.otherTopic)
                    guard canPresentNotifications else {
                        needsAnotherPass = true
                        continue
                    }
                    try await messaging.subscribe(toTopic: Self.topic)
                } else if defaults.bool(forKey: Self.registrationExistsKey) {
                    statusMessage = "お知らせの配信を停止しています…"
                    messaging.isAutoInitEnabled = false
                    // Revoke the existing registration directly. Firebase 12.19.2's
                    // unsubscribe first retrieves an FCM token, which needs APNs and can
                    // create a new token. deleteToken instead deletes by sender/FID, so
                    // cleanup also works after a cold launch with no in-memory APNs token.
                    // Keep registrationExists true on failure so the next launch retries.
                    try await messaging.deleteToken()
                    registrationToken = nil
                    defaults.set(false, forKey: Self.registrationExistsKey)
                }

                if shouldSubscribe != canPresentNotifications {
                    needsAnotherPass = true
                    continue
                }
                if authorizationStatus == .denied {
                    statusMessage = "iPhoneの設定で「シフト同期」の通知を許可してください。"
                } else if authorizationStatus == .provisional {
                    statusMessage = "お知らせは通知センターに静かに届きます。"
                } else {
                    statusMessage = nil
                }
            } catch {
                if shouldSubscribe != canPresentNotifications {
                    needsAnotherPass = true
                    continue
                }
                statusMessage = shouldSubscribe
                    ? "お知らせを登録できませんでした。次回アプリを開いたときに再試行します。"
                    : "配信停止を反映できていません。オンラインでアプリを開くと再試行します。"
                // Firebase also retries topic operations; keep our desired state for the next launch.
                needsAnotherPass = false
            }
        } while needsAnotherPass
    }
}
