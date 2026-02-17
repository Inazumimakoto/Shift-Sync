import SwiftUI
import Combine
import WebKit

enum LaunchDestination: String, CaseIterable, Identifiable {
    case shifts
    case timecard

    static let storageKey = "launchDestination"

    var id: String { rawValue }

    var tabLabel: String {
        switch self {
        case .shifts:
            return "シフト"
        case .timecard:
            return "打刻"
        }
    }

    var launchOptionLabel: String {
        switch self {
        case .shifts:
            return "シフト一覧"
        case .timecard:
            return "打刻ページ"
        }
    }

    var systemImage: String {
        switch self {
        case .shifts:
            return "calendar"
        case .timecard:
            return "clock.badge"
        }
    }
}

enum AppPreferenceKeys {
    static let hasSeenTimecardGuide = "hasSeenTimecardGuide"
}

enum SettingsScrollTarget: Hashable {
    case launchDestination
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage(LaunchDestination.storageKey) private var launchDestinationRawValue = LaunchDestination.shifts.rawValue

    @State private var selectedTab: LaunchDestination = .shifts
    @State private var didApplyInitialTab = false
    @State private var isSyncing = false
    @State private var showingSettings = false
    @State private var settingsScrollTarget: SettingsScrollTarget?
    @State private var showingSetup = false
    @State private var syncError: String?
    
    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                shiftTabView
                    .tag(LaunchDestination.shifts)
                    .tabItem {
                        Label(LaunchDestination.shifts.tabLabel, systemImage: LaunchDestination.shifts.systemImage)
                    }

                TimecardPageView {
                    openLaunchDestinationSettings()
                }
                    .tag(LaunchDestination.timecard)
                    .tabItem {
                        Label(LaunchDestination.timecard.tabLabel, systemImage: LaunchDestination.timecard.systemImage)
                    }
            }
            .navigationTitle("シフト同期")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(selectedTab == .timecard ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if selectedTab == .shifts {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: {
                settingsScrollTarget = nil
            }) {
                SettingsView(initialScrollTarget: settingsScrollTarget)
            }
            .fullScreenCover(isPresented: $showingSetup) {
                SetupView()
            }
            .onAppear {
                applyInitialTabIfNeeded()
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
            .onChange(of: launchDestinationRawValue) { _, newValue in
                guard let destination = LaunchDestination(rawValue: newValue) else { return }
                selectedTab = destination
            }
            .alert("同期エラー", isPresented: .constant(syncError != nil)) {
                Button("OK") { syncError = nil }
            } message: {
                Text(syncError ?? "")
            }
        }
    }

    private var shiftTabView: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ヘッダー
                headerSection

                // シフト一覧
                if appState.shifts.isEmpty {
                    emptyStateView
                        .padding(.bottom, 90)
                } else {
                    shiftListView
                }
            }

            // 同期ボタン（フローティング）
            syncButton
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
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
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 88)
        }
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
            .frame(height: 54)
            .background(Color.blue.gradient)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        .disabled(isSyncing || !appState.isLoggedIn)
    }
    
    // MARK: - Actions

    private func applyInitialTabIfNeeded() {
        guard !didApplyInitialTab else { return }
        selectedTab = LaunchDestination(rawValue: launchDestinationRawValue) ?? .shifts
        didApplyInitialTab = true
    }

    private func openLaunchDestinationSettings() {
        settingsScrollTarget = .launchDestination
        showingSettings = true
    }

    private func performSync() {
        guard !isSyncing else { return }
        
        // デモモードでは同期をスキップ
        if appState.isDemoMode {
            return
        }
        
        isSyncing = true
        
        Task {
            do {
                _ = try await BackgroundTaskManager.shared.performSync(source: .manual)
                
                await MainActor.run {
                    appState.shifts = SharedStorage.loadShifts()
                    appState.lastSyncDate = SharedStorage.loadLastSyncDate()
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
        appState.shifts = SharedStorage.loadShifts()
        if let lastSync = SharedStorage.loadLastSyncDate() {
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

struct TimecardPageView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage(AppPreferenceKeys.hasSeenTimecardGuide) private var hasSeenTimecardGuide = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingTimecardGuideBanner = false
    @State private var timecardGuideTask: Task<Void, Never>?

    let onOpenLaunchDestinationSettings: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea(edges: [.top, .bottom])

            if appState.isLoggedIn {
                TimecardWebView(
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea(edges: [.top, .bottom])
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.key")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("ShiftWebにログインすると打刻ページを表示できます")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            if appState.isLoggedIn && isLoading {
                ProgressView("読み込み中...")
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .top) {
            if showingTimecardGuideBanner {
                TimecardGuideBanner {
                    dismissGuideBanner()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onOpenLaunchDestinationSettings()
                    }
                } onDismiss: {
                    dismissGuideBanner()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .alert("打刻ページエラー", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            scheduleTimecardGuideIfNeeded()
        }
        .onDisappear {
            timecardGuideTask?.cancel()
            timecardGuideTask = nil
        }
    }

    private func scheduleTimecardGuideIfNeeded() {
        guard !hasSeenTimecardGuide, timecardGuideTask == nil else { return }

        timecardGuideTask = Task { @MainActor in
            defer { timecardGuideTask = nil }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, !hasSeenTimecardGuide else { return }

            hasSeenTimecardGuide = true
            withAnimation(.easeInOut(duration: 0.25)) {
                showingTimecardGuideBanner = true
            }
        }
    }

    private func dismissGuideBanner() {
        withAnimation(.easeOut(duration: 0.2)) {
            showingTimecardGuideBanner = false
        }
    }
}

private struct TimecardGuideBanner: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(.orange)
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("出勤・休憩・退勤の打刻が、このアプリでできるようになりました。")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Tips: 「設定 > 起動時に表示」で、打刻ページを最初に開けます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Button("設定を開く", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
    }
}

struct TimecardWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?

    let timecardURL = URL(string: "https://ams-app.club/timecard.php")!

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        context.coordinator.loadInitialPage(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: TimecardWebView

        private var autoLoginAttempts = 0
        private let maxAutoLoginAttempts = 2
        private var didForceOpenTimecardAfterLogin = false

        init(_ parent: TimecardWebView) {
            self.parent = parent
        }

        func loadInitialPage(_ webView: WKWebView) {
            autoLoginAttempts = 0
            didForceOpenTimecardAfterLogin = false
            parent.isLoading = true
            parent.errorMessage = nil
            webView.load(URLRequest(url: parent.timecardURL))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false

            guard let url = webView.url else { return }
            let absoluteURL = url.absoluteString

            if absoluteURL.contains("login.php") {
                attemptAutoLogin(webView)
                return
            }

            if absoluteURL.contains("timecard.php") {
                return
            }

            if absoluteURL.contains("ams-app.club"), !didForceOpenTimecardAfterLogin {
                didForceOpenTimecardAfterLogin = true
                webView.load(URLRequest(url: parent.timecardURL))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.errorMessage = "ページの読み込みに失敗しました: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.errorMessage = "ページの読み込みに失敗しました: \(error.localizedDescription)"
        }

        private func attemptAutoLogin(_ webView: WKWebView) {
            guard autoLoginAttempts < maxAutoLoginAttempts else {
                parent.errorMessage = "自動ログインに失敗しました。設定からShiftWebに再ログインしてください。"
                return
            }

            guard let credentials = try? KeychainService.shared.getShiftWebCredentials() else {
                parent.errorMessage = "キーチェーンにShiftWebのID/PASSが見つかりません。"
                return
            }

            autoLoginAttempts += 1

            let escapedID = jsEscaped(credentials.id)
            let escapedPassword = jsEscaped(credentials.password)

            let script = """
            (function() {
                var idInput = document.getElementById('id') ||
                              document.querySelector('input[name="id"]') ||
                              document.querySelector('input[type="text"]');
                var passwordInput = document.getElementById('password') ||
                                    document.querySelector('input[name="password"]') ||
                                    document.querySelector('input[type="password"]');
                if (!idInput || !passwordInput) {
                    return 'fields_not_found';
                }
                idInput.value = '\(escapedID)';
                passwordInput.value = '\(escapedPassword)';

                var form = idInput.form || passwordInput.form || document.querySelector('form');
                if (form) {
                    form.submit();
                    return 'submitted';
                }

                var submitButton = document.querySelector('button[type="submit"], input[type="submit"]');
                if (submitButton) {
                    submitButton.click();
                    return 'clicked';
                }

                return 'submit_not_found';
            })();
            """

            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.parent.errorMessage = "自動ログインに失敗しました: \(error.localizedDescription)"
                }
            }
        }

        private func jsEscaped(_ text: String) -> String {
            text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
