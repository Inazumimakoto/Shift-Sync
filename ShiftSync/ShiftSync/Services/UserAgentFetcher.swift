import Foundation
import WebKit
import SwiftUI

/// アプリ起動時に裏でUser-Agentを取得するためのクラス
class UserAgentFetcher: NSObject {
    static let shared = UserAgentFetcher()
    private var webView: WKWebView?
    
    /// User-Agentが未保存の場合、または強制的に更新したい場合に実行
    func fetchUserAgentIfNeeded() {
        // すでに保存済みなら何もしない（今回は「念の為毎回更新」という要望ならここを削除）
        // 今回の要望は「既存ユーザーも救いたい」なので、
        // 単純に「アプリ起動時に1回実行」でOK。
        // リソース節約のため、すでに保存済みならスキップするロジックにするのが一般的だが、
        // OSアップデートなどでUAが変わることもあるので、起動時に毎回チェックしても問題ない軽さ。
        
        DispatchQueue.main.async {
            self.startFetching()
        }
    }
    
    private func startFetching() {
        let config = WKWebViewConfiguration()
        // 画面には表示しないのでframeはzero
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView?.navigationDelegate = self
        
        // ダミーのページをロードする必要はなく、WebViewを作った時点でJSは実行可能
        // ただし、確実にコンテキストが有効になるように、about:blankをロードしてから実行するのが安全
        self.webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

extension UserAgentFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] (result, error) in
            if let userAgent = result as? String {
                print("Background User-Agent Fetch: \(userAgent)")
                
                // 保存
                UserDefaults.standard.set(userAgent, forKey: "UserAgent")
                
                // 完了したらWebViewを解放
                self?.webView = nil
            }
        }
    }
}
