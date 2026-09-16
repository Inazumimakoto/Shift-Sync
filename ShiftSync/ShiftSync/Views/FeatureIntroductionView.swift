import SwiftUI

enum FeatureIntroduction {
    static let featureID = "clock-out-alarm-v1"
    static let seenKey = "hasSeenClockOutAlarmIntroductionV1"
}

enum FeaturePresentation: Identifiable {
    case introduction
    case announcement(AppAnnouncement)

    var id: String {
        switch self {
        case .introduction: return FeatureIntroduction.featureID
        case .announcement(let announcement): return announcement.id
        }
    }
}

struct FeatureIntroductionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var alarms = AlarmCoordinator.shared
    @AppStorage(FeatureIntroduction.seenKey) private var hasSeenIntroduction = false

    @State private var isEnablingAlarm = false
    @State private var didTryEnablingAlarm = false
    @State private var didEnableFromThisPresentation = false
    @State private var wasEnabledBeforeRequest = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer(minLength: 24)
                        alarmStep
                        Spacer(minLength: 24)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("新機能のお知らせ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", systemImage: "xmark") {
                        cancelPendingAlarmEnable()
                        dismiss()
                    }
                }
            }
            .onAppear { hasSeenIntroduction = true }
        }
    }

    private var alarmIsReady: Bool {
        didEnableFromThisPresentation && alarms.isEnabled && alarms.isAuthorized && !isEnablingAlarm
    }

    private var alarmStep: some View {
        VStack(spacing: 24) {
            Image(systemName: alarmIsReady ? "checkmark.circle.fill" : "alarm.fill")
                .font(.system(size: 60))
                .foregroundStyle(alarmIsReady ? .green : .orange)
                .accessibilityHidden(true)

            Text(alarmIsReady ? "アラームを有効にしました" : "19:45の退勤アラーム")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if alarmIsReady {
                alarmResult
                primaryButton("完了") { dismiss() }
            } else {
                Text("退勤予定が19:45の日に、打刻を忘れないようアラームでお知らせします。有効にすると、シフトに合わせてアラームが自動で設定され、当日の19:45に鳴ります。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if didTryEnablingAlarm, !isEnablingAlarm, let status = alarms.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                primaryButton("有効にする", isWorking: isEnablingAlarm) {
                    wasEnabledBeforeRequest = alarms.isEnabled
                    isEnablingAlarm = true
                    didTryEnablingAlarm = true
                    Task {
                        await alarms.setEnabled(true)
                        didEnableFromThisPresentation = alarms.isEnabled && alarms.isAuthorized
                        isEnablingAlarm = false
                    }
                }
                .disabled(isEnablingAlarm || alarms.isBusy || appState.isDemoMode)
                .accessibilityIdentifier("enableClockOutAlarmFromIntroduction")

                if didTryEnablingAlarm && !isEnablingAlarm && !alarms.isAuthorized {
                    Button("iPhoneの設定を開く", action: openSystemSettings)
                        .font(.subheadline)
                }

                Button("あとで") {
                    cancelPendingAlarmEnable()
                    dismiss()
                }
                    .foregroundStyle(.secondary)

                Text(appState.isDemoMode
                     ? "デモモードではアラームを設定できません。"
                     : "消音・集中モード中も音が鳴ります。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 380)
    }

    private var alarmResult: some View {
        VStack(spacing: 12) {
            if let status = alarms.statusMessage {
                Text(status)
                    .foregroundStyle(.secondary)
            } else if let nextAlarmDate = alarms.nextAlarmDate {
                Text("次のアラーム")
                    .foregroundStyle(.secondary)
                Text(AlarmDateDisplay.string(from: nextAlarmDate))
                    .font(.headline)
            } else if alarms.pendingCount == 0 {
                Text("現在、予約済みのアラームはありません。")
                    .foregroundStyle(.secondary)
            }
            if alarms.pendingCount > 0 && alarms.statusMessage == nil {
                Text("予約できていないアラームがあります。\n設定から確認してください。")
                    .foregroundStyle(.secondary)
            }
            Text("設定の「予約済み」から、日ごとにオン・オフを変更できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private func primaryButton(_ title: String, isWorking: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isWorking { ProgressView().tint(.white) }
                Text(isWorking ? "設定中…" : title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 16)
    }

    private func cancelPendingAlarmEnable() {
        guard isEnablingAlarm, !wasEnabledBeforeRequest else { return }
        Task { await alarms.setEnabled(false) }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

struct AnnouncementDetailView: View {
    let announcement: AppAnnouncement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(announcement.title)
                        .font(.title2.bold())
                    Text(announcement.body)
                        .textSelection(.enabled)
                    if let featureID = announcement.featureID,
                       featureID != FeatureIntroduction.featureID {
                        Text("この機能を利用するには、最新バージョンを確認してください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link("TestFlightで最新バージョンを確認", destination: URL(string: "https://testflight.apple.com/join/Cjyt88rk")!)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("お知らせ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
