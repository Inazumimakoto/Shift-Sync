import SwiftUI
import WebKit

/// WebViewでShiftWebにログインし、Face ID自動入力を利用してID/パスワードを取得
struct ShiftWebLoginView: View {
    let promptMessage: String?
    let onComplete: (Bool) -> Void
    
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var extractedCredentials: (id: String, password: String)?

    init(promptMessage: String? = nil, onComplete: @escaping (Bool) -> Void) {
        self.promptMessage = promptMessage
        self.onComplete = onComplete
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let promptMessage, !promptMessage.isEmpty {
                    Text(promptMessage)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.15))
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }

                ZStack {
                    ShiftWebWebView(
                        isLoading: $isLoading,
                        extractedCredentials: $extractedCredentials,
                        onLoginSuccess: { id, password in
                            saveCredentialsAndDismiss(id: id, password: password)
                        },
                        onError: { error in
                            errorMessage = error
                        }
                    )

                    if isLoading {
                        ProgressView("読み込み中...")
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .navigationTitle("ShiftWebログイン")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                        onComplete(false)
                    }
                }
            }
            .alert("エラー", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
    
    private func saveCredentialsAndDismiss(id: String, password: String) {
        guard !id.isEmpty, !password.isEmpty else {
            errorMessage = "IDまたはパスワードが取得できませんでした"
            return
        }
        
        do {
            try KeychainService.shared.saveShiftWebCredentials(id: id, password: password)
            dismiss()
            onComplete(true)
        } catch {
            errorMessage = "認証情報の保存に失敗しました: \(error.localizedDescription)"
        }
    }
}

struct ShiftWebWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    @Binding var extractedCredentials: (id: String, password: String)?
    let onLoginSuccess: (String, String) -> Void
    let onError: (String) -> Void
    
    private let loginURL = URL(string: "https://ams-app.club/login.php")!
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        
        // JavaScriptからSwiftにメッセージを送るハンドラーを追加
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "loginHandler")
        
        // フォーム送信をインターセプトするJavaScriptを注入
        let interceptScript = WKUserScript(
            source: Self.formInterceptScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(interceptScript)
        
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // ShiftWebサイトのCookieをクリアしてからログインページを読み込む
        clearShiftWebCookies {
            webView.load(URLRequest(url: self.loginURL))
        }
        
        return webView
    }
    
    /// ShiftWebサイトのCookieをクリア
    private func clearShiftWebCookies(completion: @escaping () -> Void) {
        let dataStore = WKWebsiteDataStore.default()
        
        // Cookieとセッションデータを削除
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage
        ]
        
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            // ams-app.clubのデータのみ削除
            let webRecords = records.filter { $0.displayName.contains("ams-app.club") }
            
            if webRecords.isEmpty {
                completion()
            } else {
                dataStore.removeData(ofTypes: dataTypes, for: webRecords) {
                    print("Cleared ShiftWeb cookies: \(webRecords.count) records")
                    completion()
                }
            }
        }
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // フォーム送信をインターセプトするJavaScript
    // ログインAPIリクエストもフック
    static let formInterceptScript = """
    (function() {
        console.log('ShiftWeb Login Script Loaded');
        
        // フォームを見つけてsubmitイベントをリッスン
        function setupFormListener() {
            var form = document.querySelector('form');
            if (form && !form._hooked) {
                form._hooked = true;
                console.log('Form found, setting up listener');
                
                form.addEventListener('submit', function(e) {
                    console.log('Form submit detected');
                    captureCredentials();
                });
            }
            
            // ログインボタンのクリックも監視
            var loginBtn = document.querySelector('input[type="submit"], button[type="submit"], .login-btn, #login-btn');
            if (loginBtn && !loginBtn._hooked) {
                loginBtn._hooked = true;
                loginBtn.addEventListener('click', function(e) {
                    console.log('Login button clicked');
                    captureCredentials();
                });
            }
        }
        
        function captureCredentials() {
            var idInput = document.getElementById('id') || 
                          document.querySelector('input[name="id"]') ||
                          document.querySelector('input[type="text"]');
            var passwordInput = document.getElementById('password') || 
                                document.querySelector('input[name="password"]') ||
                                document.querySelector('input[type="password"]');
            
            if (idInput && passwordInput && idInput.value && passwordInput.value) {
                console.log('Credentials captured');
                var credentials = {
                    id: idInput.value,
                    password: passwordInput.value
                };
                try {
                    window.webkit.messageHandlers.loginHandler.postMessage(credentials);
                } catch(e) {
                    console.error('Failed to send credentials:', e);
                }
            }
        }

        function normalizeMessage(message) {
            if (!message) {
                return '';
            }
            return message
                .replace(/<br\\s*\\/?>/gi, '\\n')
                .replace(/<[^>]*>/g, '')
                .replace(/&nbsp;/g, ' ')
                .trim();
        }

        function postLoginResult(success, message) {
            try {
                window.webkit.messageHandlers.loginHandler.postMessage({
                    type: success ? 'loginSuccess' : 'loginFailure',
                    message: normalizeMessage(message || '')
                });
            } catch(e) {
                console.error('Failed to send login result:', e);
            }
        }

        function handleLoginResponse(status, responseText) {
            console.log('Login API response:', status, responseText);
            if (status !== 200) {
                postLoginResult(false, 'ログインに失敗しました。');
                return;
            }

            try {
                var parsed = JSON.parse(responseText);
                if (parsed && parsed.cookie === true) {
                    postLoginResult(true, parsed.msg || '');
                } else {
                    postLoginResult(false, parsed ? parsed.msg : 'ログインに失敗しました。');
                }
            } catch (e) {
                postLoginResult(false, 'ログイン結果を確認できませんでした。');
            }
        }
        
        // XMLHttpRequestをフック（AJAXログインを検出）
        var originalXHR = window.XMLHttpRequest;
        window.XMLHttpRequest = function() {
            var xhr = new originalXHR();
            var originalOpen = xhr.open;
            var originalSend = xhr.send;
            
            xhr.open = function(method, url) {
                this._url = url;
                return originalOpen.apply(this, arguments);
            };
            
            xhr.send = function(data) {
                // ログインAPIへのリクエストを検出
                if (this._url && this._url.includes('check_login')) {
                    console.log('Login API request detected');
                    captureCredentials();
                    
                    // レスポンスを監視
                    var self = this;
                    this.addEventListener('load', function() {
                        handleLoginResponse(self.status, self.responseText || '');
                    });
                }
                return originalSend.apply(this, arguments);
            };
            
            return xhr;
        };
        
        // fetchもフック
        var originalFetch = window.fetch;
        window.fetch = function(url, options) {
            if (url && url.toString().includes('check_login')) {
                console.log('Login fetch request detected');
                captureCredentials();
            }
            return originalFetch.apply(this, arguments).then(function(response) {
                if (url && url.toString().includes('check_login')) {
                    response.clone().text().then(function(text) {
                        handleLoginResponse(response.status, text || '');
                    }).catch(function() {
                        postLoginResult(false, 'ログイン結果を確認できませんでした。');
                    });
                }
                return response;
            });
        };
        
        // DOMの準備ができたらセットアップ
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', setupFormListener);
        } else {
            setupFormListener();
        }
        
        // 念のため遅延してもう一度セットアップ
        setTimeout(setupFormListener, 500);
        setTimeout(setupFormListener, 1000);
        setTimeout(setupFormListener, 2000);
    })();
    """
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let parent: ShiftWebWebView
        private var capturedCredentials: (id: String, password: String)?
        private var hasCompletedLogin = false
        
        init(_ parent: ShiftWebWebView) {
            self.parent = parent
        }
        
        // JavaScriptからのメッセージを受信
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "loginHandler" else { return }
            
            if let body = message.body as? [String: String] {
                // loginSuccess メッセージの処理
                if body["type"] == "loginSuccess" {
                    Task { @MainActor in
                        if let creds = self.capturedCredentials, !self.hasCompletedLogin {
                            self.hasCompletedLogin = true
                            self.parent.onLoginSuccess(creds.id, creds.password)
                        }
                    }
                    return
                }

                if body["type"] == "loginFailure" {
                    Task { @MainActor in
                        let message = ShiftWebPageInspector.sanitizedMessage(body["message"]) ?? "ログインに失敗しました。IDとパスワードを確認してください。"
                        self.parent.onError(message)
                    }
                    return
                }
                
                // 認証情報のキャプチャ
                if let id = body["id"], let password = body["password"] {
                    print("Captured credentials: id=\(id)")
                    Task { @MainActor in
                        self.capturedCredentials = (id, password)
                        self.parent.extractedCredentials = (id, password)
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                self.parent.isLoading = true
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.parent.isLoading = false
            }

            // User-Agentを取得して保存
            webView.evaluateJavaScript("navigator.userAgent") { (result, error) in
                if let userAgent = result as? String {
                    print("Captured User-Agent: \(userAgent)")
                    UserDefaults.standard.set(userAgent, forKey: "UserAgent")
                }
            }
            
            guard let url = webView.url?.absoluteString else { return }
            print("Navigation finished: \(url)")
            
            // ログイン成功を検出（ログインページ以外に遷移）
            let isLoginPage = url.contains("login.php") || url.hasSuffix("login")
            let isShiftWebSite = url.contains("ams-app.club")
            
            if isShiftWebSite && !isLoginPage && !hasCompletedLogin {
                checkLoginStatus(webView)
            }
        }
        
        private func checkLoginStatus(_ webView: WKWebView) {
            // ページに特定の要素があるか確認（ログイン済みの証拠）
            let js = """
            (function() {
                // ログアウトボタンやユーザー名表示があればログイン済み
                var logoutLink = document.querySelector('a[href*="logout"]');
                var shiftTable = document.getElementById('shiftTable');
                return (logoutLink !== null || shiftTable !== null);
            })();
            """
            
            webView.evaluateJavaScript(js) { [weak self] result, error in
                if let isLoggedIn = result as? Bool, isLoggedIn {
                    Task { @MainActor in
                        guard let self else { return }
                        guard !self.hasCompletedLogin else { return }

                        if let creds = self.capturedCredentials {
                            self.hasCompletedLogin = true
                            self.parent.onLoginSuccess(creds.id, creds.password)
                        } else {
                            self.parent.onError("ログインは成功しましたが、認証情報を保存できませんでした。再度ログインしてください。")
                        }
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                self.parent.isLoading = false
            }
        }
    }
}

#Preview {
    ShiftWebLoginView { _ in }
}
