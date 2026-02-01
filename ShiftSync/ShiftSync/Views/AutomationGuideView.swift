import SwiftUI

struct AutomationGuideView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // ヘッダー
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 50))
                            .foregroundStyle(.blue)
                        
                        Text("オートメーションで自動同期")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("iOSのショートカットアプリを使って、毎日自動でシフトを同期できます")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top)
                    
                    // ショートカットを開くボタン
                    Button {
                        openShortcutsApp()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.forward.app")
                            Text("ショートカットアプリを開く")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)
                    
                    Divider()
                    
                    // 設定手順
                    VStack(alignment: .leading, spacing: 20) {
                        Text("設定手順")
                            .font(.headline)
                        
                        StepRow(number: 1, text: "「ショートカット」アプリを開く")
                        StepRow(number: 2, text: "下の「オートメーション」タブをタップ")
                        StepRow(number: 3, text: "右上の「＋」をタップして新規作成")
                        StepRow(number: 4, text: "トリガーを選択\n（例：「時刻」で毎朝7:00、「充電時」、「Wi-Fi接続時」など）")
                        StepRow(number: 5, text: "「すぐに実行」を選択、「実行時に通知」はOFF推奨")
                        StepRow(number: 6, text: "「次に」をタップ")
                        StepRow(number: 7, text: "下の検索バーで「シフト同期」を検索して「シフトを同期」を選択")
                        StepRow(number: 8, text: "完了！")
                    }
                    
                    Divider()
                    
                    // 補足情報
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.blue)
                            Text("補足")
                                .font(.headline)
                        }
                        
                        Text("• アプリを開くと自動的に同期が開始されます（前回から1時間以上経過時）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text("• 画面ロック中でもバックグラウンドで動作します")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text("• 通知がオンの場合、同期完了時にアプリ内通知でお知らせします")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Text("• アプリ自体もバックグラウンド同期に対応していますが、iOSの仕様上あまり実行されないためオートメーションの利用をおすすめします")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("オートメーション")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func openShortcutsApp() {
        if let url = URL(string: "shortcuts://") {
            UIApplication.shared.open(url)
        }
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.blue)
                .clipShape(Circle())
            
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    AutomationGuideView()
}
