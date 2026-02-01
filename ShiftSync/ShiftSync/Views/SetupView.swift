import SwiftUI
import EventKit

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var currentStep = 0
    @State private var showingShiftWebLogin = false
    @State private var isRequestingCalendarAccess = false
    @State private var calendarAccessGranted = false
    @State private var selectedCalendar: EKCalendarWrapper?
    @State private var availableCalendars: [EKCalendarWrapper] = []
    @State private var showingNewCalendarAlert = false
    @State private var newCalendarName = ""
    @State private var alertError: String?
    @State private var notificationEnabled = false
    @State private var isSyncing = false
    
    // ステップ数
    private let totalSteps = 4
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // プログレスインジケーター
                HStack(spacing: 8) {
                    ForEach(0..<totalSteps, id: \.self) { step in
                        Circle()
                            .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.top)
                
                Spacer()
                
                // ステップコンテンツ
                switch currentStep {
                case 0:
                    step1ShiftWebLogin
                case 1:
                    step2Notification
                case 2:
                    step3CalendarAccess
                case 3:
                    step4CalendarSelection
                default:
                    EmptyView()
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("セットアップ")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingShiftWebLogin) {
                ShiftWebLoginView { success in
                    if success {
                        appState.isLoggedIn = true
                        withAnimation {
                            currentStep = 1
                        }
                    }
                }
            }
            .alert("新しいカレンダーを作成", isPresented: $showingNewCalendarAlert) {
                TextField("カレンダー名", text: $newCalendarName)
                Button("キャンセル", role: .cancel) {
                    newCalendarName = ""
                }
                Button("作成") {
                    createNewCalendar()
                }
            } message: {
                Text("シフト用のカレンダー名を入力してください")
            }
            .alert("エラー", isPresented: .constant(alertError != nil)) {
                Button("OK") { alertError = nil }
            } message: {
                Text(alertError ?? "")
            }
        }
    }
    
    // MARK: - Step 1: ShiftWeb Login
    
    private var step1ShiftWebLogin: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("ShiftWebにログイン")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("バイト先のシフト管理サイトに\nログインしてください")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button {
                showingShiftWebLogin = true
            } label: {
                Text("ログイン")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            
            // デモモードボタン（Apple審査用）
            Button {
                enterDemoMode()
            } label: {
                Text("デモモードで試す")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            }
            .padding(.top, 8)
        }
    }
    
    private func enterDemoMode() {
        appState.isDemoMode = true
        appState.isLoggedIn = true
        
        // デモ用のサンプルシフトを生成
        let calendar = Calendar.current
        var demoShifts: [Shift] = []
        
        // 今日から2週間分のサンプルシフトを作成
        for dayOffset in [1, 3, 5, 7, 10, 12, 14] {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: Date()) {
                let startHour = [9, 10, 11, 13].randomElement()!
                let workHours = [6, 7, 8].randomElement()!
                
                let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date)!
                let end = calendar.date(bySettingHour: startHour + workHours, minute: 0, second: 0, of: date)!
                
                let shift = Shift(
                    uid: "demo-\(dayOffset)",
                    title: "バイト",
                    start: start,
                    end: end,
                    location: ["本社", "支店A", "支店B"].randomElement()!,
                    memo: ""
                )
                demoShifts.append(shift)
            }
        }
        
        appState.shifts = demoShifts
        UserDefaults.standard.set(true, forKey: "isDemoMode")
        
        withAnimation {
            currentStep = 1
        }
    }
    
    // MARK: - Step 2: Notification Permission
    
    private var step2Notification: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            
            Text("通知の許可")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("シフトに更新・新規登録があった時のみ\n通知でお知らせします")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button {
                requestNotificationPermission()
            } label: {
                Text("通知を許可")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 40)
            
            Button("通知なしで続ける") {
                withAnimation {
                    currentStep = 2
                }
            }
            .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Step 3: Calendar Access
    
    private var step3CalendarAccess: some View {
        VStack(spacing: 24) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("カレンダーへのアクセス")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("シフトをカレンダーに登録するために\nアクセス許可が必要です")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            Button {
                requestCalendarAccess()
            } label: {
                HStack {
                    if isRequestingCalendarAccess {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("アクセスを許可")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isRequestingCalendarAccess)
            .padding(.horizontal, 40)
            
            Button("スキップ") {
                withAnimation {
                    currentStep = 3
                }
            }
            .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Step 4: Calendar Selection & Complete
    
    private var step4CalendarSelection: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("準備完了！")
                .font(.title2)
                .fontWeight(.bold)
            
            if calendarAccessGranted {
                Text("シフトを登録するカレンダーを選択してください")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                
                // カレンダー選択メニュー
                Menu {
                    // 既存のカレンダー
                    ForEach(availableCalendars, id: \.id) { calendar in
                        Button {
                            selectedCalendar = calendar
                        } label: {
                            if selectedCalendar?.id == calendar.id {
                                Label(calendar.title, systemImage: "checkmark")
                            } else {
                                Text(calendar.title)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // 新規作成オプション
                    Button {
                        newCalendarName = "シフト"
                        showingNewCalendarAlert = true
                    } label: {
                        Label("新しいカレンダーを作成...", systemImage: "plus")
                    }
                } label: {
                    HStack {
                        Text(selectedCalendar?.title ?? "選択してください")
                            .foregroundStyle(selectedCalendar == nil ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 40)
            } else {
                Text("カレンダー同期なしで使用します\n後から設定で変更できます")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            
            Button {
                completeSetup()
            } label: {
                HStack {
                    if isSyncing {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 4)
                    }
                    Text(isSyncing ? "同期中..." : "完了")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isSyncing)
            .padding(.horizontal, 40)
        }
    }
    
    // MARK: - Actions
    
    private func requestNotificationPermission() {
        NotificationManager.shared.requestPermission()
        notificationEnabled = true
        withAnimation {
            currentStep = 2
        }
    }
    
    private func requestCalendarAccess() {
        isRequestingCalendarAccess = true
        
        Task {
            do {
                let granted = try await CalendarService.shared.requestAccess()
                
                await MainActor.run {
                    calendarAccessGranted = granted
                    isRequestingCalendarAccess = false
                    
                    if granted {
                        loadCalendars()
                    }
                    
                    withAnimation {
                        currentStep = 3
                    }
                }
            } catch {
                await MainActor.run {
                    isRequestingCalendarAccess = false
                    withAnimation {
                        currentStep = 3
                    }
                }
            }
        }
    }
    
    private func loadCalendars() {
        let calendars = CalendarService.shared.getICloudCalendars()
        availableCalendars = calendars.map { EKCalendarWrapper(calendar: $0) }
    }
    
    private func createNewCalendar() {
        guard !newCalendarName.isEmpty else { return }
        
        do {
            let calendar = try CalendarService.shared.createCalendar(title: newCalendarName)
            let wrapper = EKCalendarWrapper(calendar: calendar)
            availableCalendars.append(wrapper)
            selectedCalendar = wrapper
            newCalendarName = ""
        } catch {
            alertError = "カレンダーの作成に失敗しました: \(error.localizedDescription)"
        }
    }
    
    private func completeSetup() {
        if let selected = selectedCalendar {
            UserDefaults.standard.set(selected.id, forKey: "selectedICloudCalendar")
            appState.selectedICloudCalendar = selected.id
            appState.iCloudEnabled = true
            UserDefaults.standard.set(true, forKey: "iCloudEnabled")
        }
        
        // バックグラウンド更新をスケジュール
        BackgroundTaskManager.shared.scheduleAppRefresh()
        
        // 自動同期を実行
        isSyncing = true
        Task {
            do {
                _ = try await BackgroundTaskManager.shared.performSync(source: .manual)
            } catch {
                print("初回同期エラー: \(error)")
            }
            
            await MainActor.run {
                isSyncing = false
                // 同期したシフトをAppStateに反映
                if let data = UserDefaults.standard.data(forKey: "savedShifts"),
                   let shifts = try? JSONDecoder().decode([Shift].self, from: data) {
                    appState.shifts = shifts
                }
                appState.lastSyncDate = Date()
                dismiss()
            }
        }
    }
}

struct EKCalendarWrapper: Identifiable, Hashable {
    let id: String
    let title: String
    
    init(calendar: EKCalendar) {
        self.id = calendar.calendarIdentifier
        self.title = calendar.title
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: EKCalendarWrapper, rhs: EKCalendarWrapper) -> Bool {
        lhs.id == rhs.id
    }
}

#Preview {
    SetupView()
        .environmentObject(AppState())
}
