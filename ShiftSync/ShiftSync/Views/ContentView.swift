import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var isSyncing = false
    @State private var showingSettings = false
    @State private var showingSetup = false
    @State private var syncError: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // ヘッダー
                    headerSection
                    
                    // シフト一覧
                    if appState.shifts.isEmpty {
                        emptyStateView
                    } else {
                        shiftListView
                    }
                    
                    // 同期ボタン
                    syncButton
                }
            }
            .navigationTitle("シフト同期")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showingSetup) {
                SetupView()
            }
            .onAppear {
                if !appState.isLoggedIn {
                    showingSetup = true
                } else {
                    loadShiftsFromStorage()
                    // 1時間以上経過していたら自動同期
                    autoSyncIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // バックグラウンドから戻った時にシフトを再読み込み
                loadShiftsFromStorage()
            }
            .alert("同期エラー", isPresented: .constant(syncError != nil)) {
                Button("OK") { syncError = nil }
            } message: {
                Text(syncError ?? "")
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if appState.isDemoMode {
                    Label("デモモード", systemImage: "eye.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                } else if appState.isLoggedIn {
                    Label("ログイン済み", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                } else {
                    Label("未ログイン", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
                
                Spacer()
                
                if let lastSync = appState.lastSyncDate {
                    Text("最終同期: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
    
    // MARK: - Shift List
    
    private var shiftListView: some View {
        List {
            Section("これからのシフト") {
                ForEach(upcomingShifts) { shift in
                    ShiftRowView(shift: shift)
                }
            }
            
            if !pastShifts.isEmpty {
                Section("過去のシフト") {
                    ForEach(pastShifts) { shift in
                        ShiftRowView(shift: shift)
                            .opacity(0.6)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private var upcomingShifts: [Shift] {
        appState.shifts
            .filter { $0.start >= Date() }
            .sorted { $0.start < $1.start }
    }
    
    private var pastShifts: [Shift] {
        appState.shifts
            .filter { $0.start < Date() }
            .sorted { $0.start > $1.start }
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("シフトがありません")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("「今すぐ同期」ボタンでシフトを取得してください")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
    
    // MARK: - Sync Button
    
    private var syncButton: some View {
        Button {
            performSync()
        } label: {
            HStack {
                if isSyncing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(isSyncing ? "同期中..." : "今すぐ同期")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isSyncing || !appState.isLoggedIn)
        .padding()
    }
    
    // MARK: - Actions
    
    private func performSync() {
        guard !isSyncing else { return }
        
        // デモモードでは同期をスキップ
        if appState.isDemoMode {
            return
        }
        
        isSyncing = true
        
        Task {
            do {
                let result = try await BackgroundTaskManager.shared.performSync(source: .manual)
                
                await MainActor.run {
                    // シフトを更新
                    if let data = UserDefaults.standard.data(forKey: "savedShifts"),
                       let shifts = try? JSONDecoder().decode([Shift].self, from: data) {
                        appState.shifts = shifts
                    }
                    appState.lastSyncDate = Date()
                    isSyncing = false
                }
            } catch {
                await MainActor.run {
                    syncError = error.localizedDescription
                    isSyncing = false
                }
            }
        }
    }
    
    private func autoSyncIfNeeded() {
        // デモモードでは同期しない
        guard !appState.isDemoMode else { return }
        
        // 既に同期中なら何もしない
        guard !isSyncing else { return }
        
        // 最後の同期から1時間以上経過していたら自動同期
        let autoSyncInterval: TimeInterval = 60 * 60 // 1時間
        if let lastSync = appState.lastSyncDate {
            let elapsed = Date().timeIntervalSince(lastSync)
            guard elapsed > autoSyncInterval else { return }
        }
        
        // バックグラウンドで同期実行
        performSync()
    }
    
    private func loadShiftsFromStorage() {
        if let data = UserDefaults.standard.data(forKey: "savedShifts"),
           let shifts = try? JSONDecoder().decode([Shift].self, from: data) {
            appState.shifts = shifts
        }
        if let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date {
            appState.lastSyncDate = lastSync
        }
    }
}

struct ShiftRowView: View {
    let shift: Shift
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .center, spacing: 2) {
                Text(shift.dateString)
                    .font(.headline)
                Text(shift.dayOfWeek)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(shift.timeRangeString)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: 4) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(shift.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
