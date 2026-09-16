import ActivityKit
import AlarmKit
import Foundation
import OSLog
import SwiftUI

nonisolated struct RetirementAlarmReservation: Equatable {
    let id: UUID
    let date: Date?
    let isAlerting: Bool
}

@MainActor
protocol RetirementAlarmClient {
    var authorizationState: AlarmManager.AuthorizationState { get }
    func requestAuthorization() async throws
    func reservations() throws -> [RetirementAlarmReservation]
    func schedule(id: UUID, date: Date, isTest: Bool) async throws
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
}

nonisolated struct RetirementAlarmMetadata: AlarmMetadata {}

@MainActor
final class AlarmKitRetirementAlarmClient: RetirementAlarmClient {
    private let manager = AlarmManager.shared
    private static let logger = Logger(subsystem: "com.inazumimakoto.ShiftSync", category: "AlarmKitClient")

    var authorizationState: AlarmManager.AuthorizationState { manager.authorizationState }

    func requestAuthorization() async throws {
        Self.logger.info("requestAuthorization begin")
        defer { Self.logger.info("requestAuthorization finished") }
        _ = try await manager.requestAuthorization()
    }

    func reservations() throws -> [RetirementAlarmReservation] {
        Self.logger.debug("alarms read begin")
        defer { Self.logger.debug("alarms read finished") }
        return try manager.alarms.map { alarm in
            let date: Date?
            if case .fixed(let scheduledDate) = alarm.schedule {
                date = scheduledDate
            } else {
                date = nil
            }
            return RetirementAlarmReservation(id: alarm.id, date: date, isAlerting: alarm.state == .alerting)
        }
    }

    func schedule(id: UUID, date: Date, isTest: Bool) async throws {
        Self.logger.info("schedule begin; test=\(isTest, privacy: .public)")
        defer { Self.logger.info("schedule finished") }
        // The compact system banner shares its width with the app name and controls.
        // Use the same concise title for test alarms so they preview the real alert.
        let presentation = AlarmPresentation(alert: .init(
            title: "退勤時間！",
            secondaryButton: AlarmButton(
                text: "退勤ページを開く", textColor: .white, systemImageName: "person.text.rectangle"
            ),
            secondaryButtonBehavior: .custom
        ))
        let configuration = AlarmManager.AlarmConfiguration<RetirementAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: AlarmAttributes(presentation: presentation, metadata: RetirementAlarmMetadata(), tintColor: .blue),
            stopIntent: StopRetirementAlarmIntent(alarmID: id.uuidString),
            secondaryIntent: OpenRetirementTimecardIntent(alarmID: id.uuidString),
            sound: .default
        )
        _ = try await manager.schedule(id: id, configuration: configuration)
    }

    func cancel(id: UUID) throws {
        Self.logger.info("cancel begin")
        defer { Self.logger.info("cancel finished") }
        try manager.cancel(id: id)
    }

    func stop(id: UUID) throws {
        Self.logger.info("stop begin")
        defer { Self.logger.info("stop finished") }
        try manager.stop(id: id)
    }
}
