import SwiftUI
import Combine
import GoogleSignIn

@main
struct ShiftSyncApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        BackgroundTaskManager.shared.registerBackgroundTask()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // アプリ起動時にUser-Agentを更新（裏でこっそり行う）
                    UserAgentFetcher.shared.fetchUserAgentIfNeeded()
                }
                .environmentObject(appState)
                .onAppear {
                    restoreGoogleSignIn()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }
    
    private func handleURL(_ url: URL) {
        // Google Sign-In
        if url.scheme?.contains("googleusercontent") == true {
            GIDSignIn.sharedInstance.handle(url)
            return
        }
        
        // ShiftSync URL Scheme (shiftsync://sync)
        if url.scheme == "shiftsync" {
            if url.host == "sync" || url.path == "/sync" || url.host == nil {
                // 同期をトリガー
                Task {
                    await performSyncFromURL()
                }
            }
        }
    }
    
    private func performSyncFromURL() async {
        do {
            let result = try await BackgroundTaskManager.shared.performSync(source: .automation)
            print("URL Scheme同期完了: 追加=\(result.added), 更新=\(result.updated), 削除=\(result.deleted)")
            
            // 変更があれば通知を送信
            if result.hasNotifiableChanges {
                NotificationManager.shared.sendSyncCompleteNotification(result: result)
            }
        } catch {
            print("URL Scheme同期エラー: \(error)")
            NotificationManager.shared.sendSyncErrorNotification(error: error)
        }
    }
    
    private func restoreGoogleSignIn() {
        Task {
            try? await GoogleCalendarService.shared.restorePreviousSignIn()
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var isDemoMode: Bool = false
    @Published var shifts: [Shift] = []
    @Published var lastSyncDate: Date?
    @Published var iCloudEnabled: Bool = true
    @Published var googleEnabled: Bool = false
    @Published var selectedICloudCalendar: String?
    @Published var selectedGoogleCalendar: String?
    @Published var isGoogleSignedIn: Bool = false
    
    init() {
        loadState()
    }
    
    func loadState() {
        // デモモード確認
        isDemoMode = UserDefaults.standard.bool(forKey: "isDemoMode")
        
        // KeychainからShiftWeb認証情報があるか確認、またはデモモード
        if isDemoMode || (try? KeychainService.shared.getShiftWebCredentials()) != nil {
            isLoggedIn = true
        }
        
        // UserDefaultsから設定を読み込み
        iCloudEnabled = UserDefaults.standard.bool(forKey: "iCloudEnabled")
        googleEnabled = UserDefaults.standard.bool(forKey: "googleEnabled")
        selectedICloudCalendar = UserDefaults.standard.string(forKey: "selectedICloudCalendar")
        selectedGoogleCalendar = UserDefaults.standard.string(forKey: "selectedGoogleCalendar")
        
        if let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            lastSyncDate = lastSync
        }
        
        // 保存されたシフトを読み込み
        if let data = UserDefaults.standard.data(forKey: "savedShifts"),
           let decoded = try? JSONDecoder().decode([Shift].self, from: data) {
            shifts = decoded
        }
        
        // Google Sign-In状態確認
        isGoogleSignedIn = GoogleCalendarService.shared.isSignedIn
    }
    
    func saveShifts(_ shifts: [Shift]) {
        self.shifts = shifts
        if let encoded = try? JSONEncoder().encode(shifts) {
            UserDefaults.standard.set(encoded, forKey: "savedShifts")
        }
        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: "lastSyncDate")
    }
}
