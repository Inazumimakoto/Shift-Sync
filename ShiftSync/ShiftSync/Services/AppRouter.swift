import Combine
import Foundation

nonisolated struct AppAnnouncement: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let featureID: String?

    static func fromNotification(
        title: String,
        body: String,
        userInfo: [AnyHashable: Any],
        fallbackID: String
    ) -> AppAnnouncement {
        AppAnnouncement(
            id: nonemptyString(userInfo["announcementID"]) ?? fallbackID,
            title: title.isEmpty ? "シフト同期からのお知らせ" : title,
            body: body,
            featureID: nonemptyString(userInfo["featureID"])
        )
    }

    var route: AppRoute {
        featureID == "clock-out-alarm-v1" ? .featureIntroduction : .announcement(self)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum AppRoute: Codable, Equatable, Sendable {
    case timecard
    case featureIntroduction
    case announcement(AppAnnouncement)
}

/// Keeps a notification/alarm destination until the root view can present it.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published private(set) var pendingRoute: AppRoute?

    private let defaults: UserDefaults
    private static let pendingRouteKey = "appRouter.pendingRoute.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pendingRouteKey) {
            pendingRoute = try? JSONDecoder().decode(AppRoute.self, from: data)
        }
    }

    func open(_ route: AppRoute) {
        // Clocking out takes priority over an announcement arriving during launch/login.
        guard pendingRoute != .timecard || route == .timecard else { return }
        defaults.set(try? JSONEncoder().encode(route), forKey: Self.pendingRouteKey)
        pendingRoute = route
    }

    @discardableResult
    func consumePendingRoute() -> AppRoute? {
        let route = pendingRoute
        defaults.removeObject(forKey: Self.pendingRouteKey)
        pendingRoute = nil
        return route
    }
}
