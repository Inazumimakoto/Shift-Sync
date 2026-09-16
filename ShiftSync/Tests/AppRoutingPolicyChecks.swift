import Foundation

/// Run with AppRouter.swift as a small macOS executable; does not contact Firebase or APNs.
@main
struct AppRoutingPolicyChecks {
    @MainActor
    static func main() {
        let known = AppAnnouncement.fromNotification(
            title: "退勤アラーム",
            body: "設定から利用できます。",
            userInfo: ["featureID": "clock-out-alarm-v1", "announcementID": "release-1"],
            fallbackID: "push-1"
        )
        require(known.route == .featureIntroduction, "Known feature must open its introduction")
        require(known.id == "release-1", "Console announcement ID must survive parsing")

        let unknown = AppAnnouncement.fromNotification(
            title: "アップデート",
            body: "新しいお知らせです。",
            userInfo: ["featureID": "future-feature", "announcementID": 42],
            fallbackID: "push-2"
        )
        require(unknown.route == .announcement(unknown), "Unknown features must remain readable")
        require(unknown.id == "push-2", "Malformed IDs must use the notification ID")
        let generic = AppAnnouncement.fromNotification(title: "", body: "本文", userInfo: [:], fallbackID: "push-3")
        require(generic.featureID == nil && !generic.title.isEmpty, "Generic console notices need no data keys")

        let suiteName = "AppRoutingPolicyChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let router = AppRouter(defaults: defaults)
        router.open(.announcement(unknown))
        require(AppRouter(defaults: defaults).pendingRoute == .announcement(unknown), "Cold launch must restore an unhandled tap")
        router.open(.timecard)
        router.open(.featureIntroduction)
        require(router.pendingRoute == .timecard, "Feature introduction must not interrupt clocking out")
        router.open(.announcement(known))
        require(router.pendingRoute == .timecard, "Announcement must not interrupt clocking out")
        require(router.consumePendingRoute() == .timecard, "The presented route must be consumed")
        require(AppRouter(defaults: defaults).pendingRoute == nil, "Consumed routes must not reopen on launch")
        router.open(.featureIntroduction)
        require(router.pendingRoute == .featureIntroduction, "Normal routing must resume after consumption")

        print("App routing policy checks passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
