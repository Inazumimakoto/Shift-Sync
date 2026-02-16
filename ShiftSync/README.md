# ShiftSync iOS App

バイト先のシフト管理サイト（ShiftWeb）からシフトを取得し、iCloud/Googleカレンダーに自動同期し、打刻にも使えるiOSアプリ。

## 機能

- 📱 **シフト取得**: ShiftWebからシフト情報をスクレイピング
- ⏱️ **打刻対応**: アプリ内の「打刻」タブからShiftWebの打刻ページを開いて打刻操作が可能
- 📅 **カレンダー同期**: iCloud（EventKit）、Googleカレンダー（API）
- 🔄 **バックグラウンド同期**: BGTaskSchedulerで1日数回自動同期
- 🔔 **変更通知**: 新規追加・変更・削除をプッシュ通知
- 📤 **ICSエクスポート**: カレンダーファイルとして書き出し

## セットアップ

### 1. Xcodeでプロジェクトを開く

```bash
cd /Users/inazumimakoto/Desktop/shift/ShiftSync
open ShiftSync.xcodeproj
# または Package.swift から開く場合:
# open Package.swift
```

### 2. Xcodeで必要な設定

1. **Signing & Capabilities** → 自分のTeamを選択
2. **Bundle Identifier** → `com.yourname.shiftsync` に変更
3. 以下のCapabilitiesを追加:
   - Background Modes → Background fetch を有効化
   - Keychain Sharing（オプション: Mac版と共有する場合）

### 3. SPMパッケージを解決

Xcode → File → Packages → Reset Package Caches

### 4. ビルド & 実行

⌘R でシミュレータまたは実機で実行

起動後は「打刻」タブからShiftWebの打刻ページを開けます。

## Google Calendar連携（オプション）

1. [Google Cloud Console](https://console.cloud.google.com/) でプロジェクト作成
2. Calendar API を有効化
3. OAuth 2.0 クライアントIDを作成
4. `GoogleService-Info.plist` をプロジェクトに追加

## プロジェクト構成

```
ShiftSync/
├── ShiftSyncApp.swift              # アプリエントリーポイント
├── Info.plist                      # Background Modes設定
├── Models/
│   └── Shift.swift                 # シフトデータモデル
├── Views/
│   ├── ContentView.swift           # メイン画面（シフト一覧/打刻タブ）
│   ├── SetupView.swift             # 初回セットアップ
│   ├── SettingsView.swift          # 設定画面
│   └── ShiftWebLoginView.swift          # WebViewログイン
├── Services/
│   ├── ShiftWebClient.swift             # ShiftWebスクレイピング
│   ├── ShiftParser.swift           # HTMLパース
│   ├── CalendarService.swift       # EventKit
│   ├── KeychainService.swift       # Keychain
│   └── ICSExporter.swift           # ICS出力
└── Background/
    ├── BackgroundTaskManager.swift # BGTaskScheduler
    └── NotificationManager.swift   # 通知管理
```

## Go版との互換性

このアプリは既存のGo CLI（`/Users/inazumimakoto/Desktop/shift/main.go`）と同じロジックを使用:

- **UID生成**: `shift-YYYYMMDD-HHMM-HHMM-HASH` 形式
- **Keychainサービス名**: `shift-sync-web`, `shift-sync-icloud`
- **ICS形式**: Go版と同一

Mac版と併用しても、カレンダーのイベントが重複しません。
