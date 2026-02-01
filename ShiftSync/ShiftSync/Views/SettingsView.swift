import SwiftUI
import EventKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    @State private var iCloudEnabled: Bool = true
    @State private var googleEnabled: Bool = false
    @State private var selectedCalendar: EKCalendarWrapper?
    @State private var availableCalendars: [EKCalendarWrapper] = []
    @State private var showingExportSheet = false
    @State private var exportURL: URL?
    @State private var showingLogoutConfirm = false
    @State private var showingShiftWebLogin = false
    @State private var showingNewCalendarAlert = false
    @State private var newCalendarName = ""
    @State private var alertError: String?
    
    // Google Calendar
    @State private var googleCalendars: [GoogleCalendar] = []
    @State private var selectedGoogleCalendar: GoogleCalendar?
    @State private var isLoadingGoogleCalendars = false
    @State private var isSigningInGoogle = false
    @State private var showingAutomationGuide = false
    
    // Sync History
    @State private var syncHistory: [SyncLogEntry] = []
    
    // Full History Sync
    @State private var isFullSyncing = false
    @State private var fullSyncStatus: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }
    
    private let fullSyncStartYear = 2023
    private let fullSyncStartMonth = 1
    
    var body: some View {
        NavigationStack {
            List {
                // 同期先セクション
                Section {
                    // iCloud
                    HStack {
                        Label("iCloud カレンダー", systemImage: "cloud")
                        Spacer()
                        Toggle("", isOn: $iCloudEnabled)
                            .labelsHidden()
                            .onChange(of: iCloudEnabled) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "iCloudEnabled")
                                appState.iCloudEnabled = newValue
                            }
                    }
                    
                    // iCloud カレンダー選択
                    if iCloudEnabled {
                        Menu {
                            ForEach(availableCalendars, id: \.id) { calendar in
                                Button {
                                    let oldCalendarId = selectedCalendar?.id
                                    selectedCalendar = calendar
                                    UserDefaults.standard.set(calendar.id, forKey: "selectedICloudCalendar")
                                    appState.selectedICloudCalendar = calendar.id
                                    
                                    // 古いカレンダーから新しいカレンダーに移行
                                    if let oldId = oldCalendarId, oldId != calendar.id {
                                        migrateShifts(from: oldId, to: calendar.id)
                                    }
                                } label: {
                                    if selectedCalendar?.id == calendar.id {
                                        Label(calendar.title, systemImage: "checkmark")
                                    } else {
                                        Text(calendar.title)
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Button {
                                newCalendarName = "シフト"
                                showingNewCalendarAlert = true
                            } label: {
                                Label("新しいカレンダーを作成...", systemImage: "plus")
                            }
                        } label: {
                            HStack {
                                Text("　カレンダー")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(selectedCalendar?.title ?? "未設定")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                } header: {
                    Text("iCloud")
                }
                
                // Google セクション
                Section {
                    // Google 有効化
                    HStack {
                        Label("Google カレンダー", systemImage: "g.circle")
                        Spacer()
                        Toggle("", isOn: $googleEnabled)
                            .labelsHidden()
                            .onChange(of: googleEnabled) { _, newValue in
                                UserDefaults.standard.set(newValue, forKey: "googleEnabled")
                                appState.googleEnabled = newValue
                            }
                    }
                    
                    // Google サインイン / カレンダー選択
                    if googleEnabled {
                        if GoogleCalendarService.shared.isSignedIn {
                            // サインイン済み - カレンダー選択
                            if isLoadingGoogleCalendars {
                                HStack {
                                    Text("　カレンダー")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    ProgressView()
                                }
                            } else if googleCalendars.isEmpty {
                                Button {
                                    loadGoogleCalendars()
                                } label: {
                                    HStack {
                                        Text("　カレンダー")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("読み込み")
                                    }
                                }
                            } else {
                                Picker("　カレンダー", selection: $selectedGoogleCalendar) {
                                    Text("未設定").tag(nil as GoogleCalendar?)
                                    ForEach(googleCalendars) { calendar in
                                        Text(calendar.title).tag(calendar as GoogleCalendar?)
                                    }
                                }
                                .pickerStyle(.menu)
                                .onChange(of: selectedGoogleCalendar) { _, newValue in
                                    if let id = newValue?.id {
                                        UserDefaults.standard.set(id, forKey: "selectedGoogleCalendar")
                                        appState.selectedGoogleCalendar = id
                                    }
                                }
                            }
                            
                            // サインアウト
                            Button(role: .destructive) {
                                GoogleCalendarService.shared.signOut()
                                appState.isGoogleSignedIn = false
                                googleCalendars = []
                                selectedGoogleCalendar = nil
                            } label: {
                                HStack {
                                    Text("　サインアウト")
                                    Spacer()
                                    Text(GoogleCalendarService.shared.userName ?? "")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            // 未サインイン - サインインボタン
                            Button {
                                signInGoogle()
                            } label: {
                                HStack {
                                    if isSigningInGoogle {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                    }
                                    Text("Googleにサインイン")
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isSigningInGoogle)
                        }
                    }
                } header: {
                    Text("Google")
                }
                
                // エクスポートセクション
                Section {
                    Button {
                        exportICS()
                    } label: {
                        Label("ICSファイルを書き出し", systemImage: "square.and.arrow.up")
                    }
                    .disabled(appState.shifts.isEmpty)
                } header: {
                    Text("エクスポート")
                }
                
                // ShiftWebアカウントセクション
                Section {
                    if appState.isLoggedIn {
                        HStack {
                            Label("ShiftWeb", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text("接続済み")
                                .foregroundStyle(.secondary)
                        }
                        
                        Button(role: .destructive) {
                            showingLogoutConfirm = true
                        } label: {
                            Label("ログアウト", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button {
                            showingShiftWebLogin = true
                        } label: {
                            Label("ShiftWeb にログイン", systemImage: "person.badge.key")
                        }
                    }
                } header: {
                    Text("ShiftWeb")
                } footer: {
                    if !appState.isLoggedIn {
                        Text("シフトを取得するにはShiftWebへのログインが必要です")
                    }
                }
                
                // アプリ情報
                Section {
                    Button {
                        showingAutomationGuide = true
                    } label: {
                        HStack {
                            Label("オートメーションの設定", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                    
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("情報")
                } footer: {
                    Text("バックグラウンドでも動作しますが、iOSの仕様上オートメーションの利用をおすすめします")
                }
                
                // 全履歴同期セクション
                Section {
                    Button {
                        fullSyncHistory()
                    } label: {
                        HStack {
                            if isFullSyncing {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Label("全履歴同期", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                        }
                    }
                    .disabled(!appState.isLoggedIn || isFullSyncing)
                    
                    if let status = fullSyncStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("全履歴同期")
                } footer: {
                    Text("\(fullSyncStartYear)年\(fullSyncStartMonth)月〜先月までのシフトを取得して同期します")
                }
                
                // 同期履歴セクション（折りたたみ）
                Section {
                    DisclosureGroup("同期履歴（直近20件）") {
                        if syncHistory.isEmpty {
                            Text("まだ同期履歴がありません")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(syncHistory) { entry in
                                SyncHistoryRow(entry: entry)
                            }
                        }
                    }
                }
                
                // GitHub リポジトリ
                Section {
                    Link(destination: URL(string: "https://github.com/Inazumimakoto/Shift-Sync")!) {
                        HStack {
                            Label("GitHub", systemImage: "link")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Released under the MIT License")
                }
                
                #if DEBUG
                // デバッグ用セクション（リリースビルドでは非表示）
                Section {
                    Button(role: .destructive) {
                        resetSavedShifts()
                    } label: {
                        Label("保存データをリセット", systemImage: "trash")
                    }
                    
                    Button {
                        modifyFirstShiftTime()
                    } label: {
                        Label("最初のシフト時間を変更", systemImage: "clock.arrow.2.circlepath")
                    }
                    
                    Button {
                        addFakeShift()
                    } label: {
                        Label("ダミーシフトを追加", systemImage: "plus.circle")
                    }
                } header: {
                    Text("デバッグ")
                } footer: {
                    Text("リセット→新規検出テスト\n時間変更→更新検出テスト\nダミー追加→削除検出テスト（次回同期で消える）")
                }
                #endif
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSettings()
            }
            .sheet(isPresented: $showingShiftWebLogin) {
                ShiftWebLoginView { success in
                    if success {
                        appState.isLoggedIn = true
                    }
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("ログアウト", isPresented: $showingLogoutConfirm) {
                Button("キャンセル", role: .cancel) {}
                Button("ログアウト", role: .destructive) {
                    logout()
                }
            } message: {
                Text("ShiftWebからログアウトしますか？")
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
            .sheet(isPresented: $showingAutomationGuide) {
                AutomationGuideView()
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadSettings() {
        iCloudEnabled = UserDefaults.standard.bool(forKey: "iCloudEnabled")
        googleEnabled = UserDefaults.standard.bool(forKey: "googleEnabled")
        
        // iCloudカレンダー一覧を読み込み
        if CalendarService.shared.hasAccess {
            let calendars = CalendarService.shared.getICloudCalendars()
            availableCalendars = calendars.map { EKCalendarWrapper(calendar: $0) }
            
            if let savedId = UserDefaults.standard.string(forKey: "selectedICloudCalendar") {
                selectedCalendar = availableCalendars.first { $0.id == savedId }
            }
        }
        
        // Googleカレンダーを読み込み
        if GoogleCalendarService.shared.isSignedIn {
            loadGoogleCalendars()
        }
        
        // 同期履歴を読み込み
        syncHistory = SyncHistoryManager.shared.getHistory()
    }
    
    private func signInGoogle() {
        isSigningInGoogle = true
        
        Task {
            do {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else {
                    throw GoogleCalendarError.apiError("画面が見つかりません")
                }
                
                try await GoogleCalendarService.shared.signIn(presenting: rootVC)
                
                await MainActor.run {
                    appState.isGoogleSignedIn = true
                    isSigningInGoogle = false
                    loadGoogleCalendars()
                }
            } catch {
                await MainActor.run {
                    alertError = "Googleサインインに失敗しました: \(error.localizedDescription)"
                    isSigningInGoogle = false
                }
            }
        }
    }
    
    private func loadGoogleCalendars() {
        isLoadingGoogleCalendars = true
        
        Task {
            do {
                let calendars = try await GoogleCalendarService.shared.getCalendars()
                
                await MainActor.run {
                    googleCalendars = calendars
                    isLoadingGoogleCalendars = false
                    
                    // 保存済みカレンダーを復元
                    if let savedId = UserDefaults.standard.string(forKey: "selectedGoogleCalendar") {
                        selectedGoogleCalendar = calendars.first { $0.id == savedId }
                    }
                }
            } catch {
                await MainActor.run {
                    alertError = "カレンダーの取得に失敗しました: \(error.localizedDescription)"
                    isLoadingGoogleCalendars = false
                }
            }
        }
    }
    
    private func createNewCalendar() {
        guard !newCalendarName.isEmpty else { return }
        
        // 古いカレンダーIDを保存
        let oldCalendarId = selectedCalendar?.id
        
        do {
            let calendar = try CalendarService.shared.createCalendar(title: newCalendarName)
            let wrapper = EKCalendarWrapper(calendar: calendar)
            availableCalendars.append(wrapper)
            selectedCalendar = wrapper
            UserDefaults.standard.set(wrapper.id, forKey: "selectedICloudCalendar")
            appState.selectedICloudCalendar = wrapper.id
            newCalendarName = ""
            
            // 古いカレンダーから新しいカレンダーに移行（少し遅延を入れる）
            if let oldId = oldCalendarId, oldId != wrapper.id {
                // EventKitの同期待ちのため少し遅延
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.migrateShiftsWithNewCalendar(from: oldId, to: calendar)
                }
            }
        } catch {
            alertError = "カレンダーの作成に失敗しました: \(error.localizedDescription)"
        }
    }
    
    private func migrateShiftsWithNewCalendar(from oldCalendarId: String, to newCalendar: EKCalendar) {
        guard !appState.shifts.isEmpty else { return }
        
        guard let oldCalendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == oldCalendarId }) else {
            // 古いカレンダーがなければ新しいカレンダーに追加だけ
            do {
                _ = try CalendarService.shared.syncShifts(appState.shifts, to: newCalendar)
            } catch {
                alertError = "カレンダーへの移行に失敗しました: \(error.localizedDescription)"
            }
            return
        }
        
        do {
            let range = shiftDateRange(appState.shifts)
            try CalendarService.shared.deleteAllShiftEvents(from: oldCalendar, searchStart: range.start, searchEnd: range.end)
            _ = try CalendarService.shared.syncShifts(appState.shifts, to: newCalendar)
        } catch {
            alertError = "カレンダーへの移行に失敗しました: \(error.localizedDescription)"
        }
    }
    
    private func exportICS() {
        do {
            let url = try ICSExporter.saveToTempFile(appState.shifts)
            exportURL = url
            showingExportSheet = true
        } catch {
            print("ICSエクスポートエラー: \(error)")
        }
    }
    
    private func logout() {
        do {
            try KeychainService.shared.deleteShiftWebCredentials()
            appState.isLoggedIn = false
            appState.shifts = []
        } catch {
            print("ログアウトエラー: \(error)")
        }
    }
    
    private func fullSyncHistory() {
        guard !isFullSyncing else { return }
        
        isFullSyncing = true
        fullSyncStatus = "準備中..."
        
        Task {
            do {
                let credentials = try KeychainService.shared.getShiftWebCredentials()
                try await ShiftWebClient.shared.login(id: credentials.id, password: credentials.password)
                
                let (isICloudOn, calendarId) = await MainActor.run {
                    (iCloudEnabled, UserDefaults.standard.string(forKey: "selectedICloudCalendar"))
                }
                
                guard isICloudOn else {
                    await MainActor.run {
                        fullSyncStatus = "iCloud同期がオフです"
                        isFullSyncing = false
                    }
                    return
                }
                
                guard let calendarId = calendarId,
                      let calendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == calendarId }) else {
                    await MainActor.run {
                        fullSyncStatus = "カレンダーが選択されていません"
                        isFullSyncing = false
                    }
                    return
                }
                
                let months = buildFullSyncMonths()
                guard !months.isEmpty else {
                    await MainActor.run {
                        fullSyncStatus = "同期対象の月がありません"
                        isFullSyncing = false
                    }
                    return
                }
                
                let existingShifts = await MainActor.run { appState.shifts }
                var mergedShifts = existingShifts
                var totalFetched = 0
                var totalAdded = 0
                var totalUpdated = 0
                var totalDeleted = 0
                
                for (index, month) in months.enumerated() {
                    await MainActor.run {
                        fullSyncStatus = "\(month.year)年\(month.month)月 取得中... (\(index + 1)/\(months.count))"
                    }
                    
                    let shifts = try await ShiftWebClient.shared.fetchShiftsForMonths([(year: month.year, month: month.month)])
                    totalFetched += shifts.count
                    let range = monthRange(year: month.year, month: month.month)
                    mergedShifts = replaceShifts(existing: mergedShifts, incoming: shifts, range: range)
                    
                    let result = try CalendarService.shared.syncShifts(
                        shifts,
                        to: calendar,
                        searchStart: range.start,
                        searchEnd: range.end
                    )
                    totalAdded += result.added
                    totalUpdated += result.updated
                    totalDeleted += result.deleted
                    
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                
                let sortedShifts = mergedShifts.sorted { $0.start < $1.start }
                
                await MainActor.run {
                    appState.saveShifts(sortedShifts)
                    fullSyncStatus = "完了: \(months.count)ヶ月 / \(totalFetched)件 (追加\(totalAdded)・更新\(totalUpdated)・削除\(totalDeleted))"
                    isFullSyncing = false
                }
            } catch {
                await MainActor.run {
                    fullSyncStatus = "エラー: \(error.localizedDescription)"
                    isFullSyncing = false
                }
            }
        }
    }
    
    private func buildFullSyncMonths() -> [(year: Int, month: Int)] {
        let calendar = Calendar.current
        guard let endDate = calendar.date(byAdding: .month, value: -1, to: Date()) else {
            return []
        }
        
        let endYear = calendar.component(.year, from: endDate)
        let endMonth = calendar.component(.month, from: endDate)
        
        var months: [(year: Int, month: Int)] = []
        var year = fullSyncStartYear
        var month = fullSyncStartMonth
        
        while year < endYear || (year == endYear && month <= endMonth) {
            months.append((year: year, month: month))
            month += 1
            if month > 12 {
                month = 1
                year += 1
            }
        }
        
        return months
    }
    
    private func monthRange(year: Int, month: Int) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let startDate = calendar.date(from: components)!
        let endDate = calendar.date(byAdding: .month, value: 1, to: startDate)!
        return (start: startDate, end: endDate)
    }
    
    private func shiftDateRange(_ shifts: [Shift]) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        guard let minStart = shifts.map({ $0.start }).min(),
              let maxEnd = shifts.map({ $0.end }).max() else {
            let now = Date()
            return (start: now, end: now)
        }
        
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: minStart))!
        let endMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: maxEnd))!
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: endMonthStart)!
        return (start: startOfMonth, end: endOfMonth)
    }
    
    private func replaceShifts(existing: [Shift], incoming: [Shift], range: (start: Date, end: Date)) -> [Shift] {
        let kept = existing.filter { $0.start < range.start || $0.start >= range.end }
        return kept + incoming
    }
    
    private func migrateShifts(from oldCalendarId: String, to newCalendarId: String) {
        // 現在のシフトを取得
        guard !appState.shifts.isEmpty else { return }
        
        // 新しいカレンダーを取得
        guard let newCalendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == newCalendarId }) else {
            alertError = "新しいカレンダーが見つかりません"
            return
        }
        
        // 古いカレンダーを取得
        guard let oldCalendar = CalendarService.shared.getCalendars().first(where: { $0.calendarIdentifier == oldCalendarId }) else {
            // 古いカレンダーがなければ新しいカレンダーに追加だけ
            do {
                _ = try CalendarService.shared.syncShifts(appState.shifts, to: newCalendar)
            } catch {
                alertError = "カレンダーへの移行に失敗しました: \(error.localizedDescription)"
            }
            return
        }
        
        do {
            // 古いカレンダーからシフトを削除
            let range = shiftDateRange(appState.shifts)
            try CalendarService.shared.deleteAllShiftEvents(from: oldCalendar, searchStart: range.start, searchEnd: range.end)
            
            // 新しいカレンダーにシフトを作成
            _ = try CalendarService.shared.syncShifts(appState.shifts, to: newCalendar)
        } catch {
            alertError = "カレンダーへの移行に失敗しました: \(error.localizedDescription)"
        }
    }
    
    #if DEBUG
    private func resetSavedShifts() {
        UserDefaults.standard.removeObject(forKey: "savedShifts")
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        appState.shifts = []
        appState.lastSyncDate = nil
    }
    
    private func modifyFirstShiftTime() {
        guard var shifts = loadSavedShifts(), !shifts.isEmpty else { return }
        
        // 最初のシフトの時間を1時間ずらす
        var firstShift = shifts[0]
        firstShift = Shift(
            uid: firstShift.uid,
            title: firstShift.title,
            start: firstShift.start.addingTimeInterval(3600), // +1時間
            end: firstShift.end.addingTimeInterval(3600),
            location: firstShift.location,
            memo: firstShift.memo
        )
        shifts[0] = firstShift
        
        saveSavedShifts(shifts)
        appState.shifts = shifts
    }
    
    private func addFakeShift() {
        var shifts = loadSavedShifts() ?? []
        
        // 明日のダミーシフトを追加
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
        let end = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow)!
        
        let fakeShift = Shift(
            uid: "fake-\(UUID().uuidString)",
            title: "バイト",
            start: start,
            end: end,
            location: "テスト店舗",
            memo: ""
        )
        shifts.append(fakeShift)
        
        saveSavedShifts(shifts)
        appState.shifts = shifts
    }
    
    private func loadSavedShifts() -> [Shift]? {
        guard let data = UserDefaults.standard.data(forKey: "savedShifts"),
              let shifts = try? JSONDecoder().decode([Shift].self, from: data) else {
            return nil
        }
        return shifts
    }
    
    private func saveSavedShifts(_ shifts: [Shift]) {
        if let data = try? JSONEncoder().encode(shifts) {
            UserDefaults.standard.set(data, forKey: "savedShifts")
        }
    }
    #endif
}

/// 同期履歴の1行を表示するビュー
struct SyncHistoryRow: View {
    let entry: SyncLogEntry
    
    var body: some View {
        HStack(spacing: 12) {
            // ソースアイコン
            Image(systemName: entry.source.icon)
                .font(.subheadline)
                .foregroundStyle(entry.success ? .blue : .red)
                .frame(width: 24)
            
            // 日時とソース
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.dateString)
                    .font(.subheadline)
                Text(entry.source.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // 結果
            if entry.success {
                Text(entry.result.shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
