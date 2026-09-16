import SwiftUI

enum AlarmDateDisplay {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = RetirementAlarmPolicy.calendar
        formatter.timeZone = RetirementAlarmPolicy.calendar.timeZone
        formatter.dateFormat = "MM/dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

struct AlarmSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL
    @ObservedObject private var alarms = AlarmCoordinator.shared

    var body: some View {
        Section {
            Toggle("19:45の退勤アラーム", isOn: Binding(
                get: { alarms.isEnabled || alarms.isRequestingAuthorization },
                set: { enabled in Task { await alarms.setEnabled(enabled) } }
            ))
            .disabled(alarms.isBusy || appState.isDemoMode)
            .accessibilityIdentifier("clockOutAlarmEnabled")

            if alarms.isRequestingAuthorization {
                HStack {
                    ProgressView()
                    Text("アラームの許可を確認中…")
                        .foregroundStyle(.secondary)
                }
            } else if alarms.isBusy {
                HStack {
                    ProgressView()
                    Text("アラームを更新中…")
                        .foregroundStyle(.secondary)
                }
            }

            if let nextAlarmDate = alarms.nextAlarmDate {
                LabeledContent("次のアラーム") {
                    Text(AlarmDateDisplay.string(from: nextAlarmDate))
                }
            }

            NavigationLink {
                RetirementAlarmListView()
            } label: {
                LabeledContent("予約済み", value: "\(alarms.scheduledCount)件")
            }
            .accessibilityIdentifier("reservedClockOutAlarms")

            if alarms.pendingCount > 0 {
                Text("未予約の対象シフト：\(alarms.pendingCount)件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let status = alarms.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !alarms.isAuthorized && !alarms.isRequestingAuthorization {
                Button("iPhoneのアラーム許可設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        } header: {
            Text("退勤アラーム")
        } footer: {
            Text(appState.isDemoMode
                 ? "デモモードではアラームを登録できません。"
                 : "19:45退勤のシフトだけが対象です。消音モード・集中モード中も音が鳴ります。「予約済み」から日ごとにオン・オフを変更できます。")
        }
    }
}

struct RetirementAlarmListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var alarms = AlarmCoordinator.shared

    private var targetShifts: [Shift] {
        appState.shifts.filter { AlarmCoordinator.isEligible($0) && $0.end > Date() }
            .sorted { $0.end == $1.end ? $0.uid < $1.uid : $0.end < $1.end }
    }

    var body: some View {
        List {
            if targetShifts.isEmpty {
                ContentUnavailableView(
                    "対象のシフトはありません",
                    systemImage: "alarm",
                    description: Text("今後の19:45退勤のシフトがここに表示されます。")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(targetShifts) { shift in
                        Toggle(isOn: Binding(
                            get: { alarms.isIndividuallyEnabled(for: shift) },
                            set: { enabled in Task { await alarms.setEnabled(enabled, for: shift) } }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AlarmDateDisplay.string(from: shift.end))
                                if !shift.location.isEmpty {
                                    Text(shift.location)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!alarms.isEnabled || !alarms.isAuthorized || alarms.isBusy || appState.isDemoMode)
                        .accessibilityLabel("\(AlarmDateDisplay.string(from: shift.end)) 退勤アラーム")
                        .accessibilityIdentifier("shiftAlarm-\(shift.uid)")
                    }
                } footer: {
                    Text(alarms.isEnabled
                         ? "19:45退勤の日を表示しています。オフにした日も、この一覧から戻せます。"
                         : "設定で「19:45の退勤アラーム」をオンにすると変更できます。日ごとの設定は保持されています。")
                }
            }
        }
        .navigationTitle("退勤アラーム")
        .navigationBarTitleDisplayMode(.inline)
    }
}
