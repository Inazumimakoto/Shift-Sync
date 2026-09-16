# ShiftSync iOS App

バイト先のシフト管理サイト（ShiftWeb）からシフトを取得し、iCloud/Googleカレンダーに自動同期し、打刻にも使え、ウィジェットからも同期できるiOSアプリ。

## 機能

- 📱 **シフト取得**: ShiftWebからシフト情報をスクレイピング
- ⏱️ **打刻対応**: アプリ内の「打刻」タブからShiftWebの打刻ページを開いて打刻操作が可能
- 📅 **カレンダー同期**: iCloud（EventKit）、Googleカレンダー（API）
- 🧩 **ウィジェット同期**: ホーム画面ウィジェットの「同期」ボタンから同期を実行可能
- 🔄 **バックグラウンド同期**: BGTaskSchedulerで1日数回自動同期
- 🔔 **変更通知**: 新規追加・変更・削除をローカル通知
- ⏰ **退勤アラーム**: 19:45退勤のシフトをAlarmKitで予約。シフトごとの切替と打刻画面への移動に対応
- 📣 **新機能のお知らせ**: OS通知を許可した端末へFirebaseプッシュ通知を配信
- 📤 **ICSエクスポート**: カレンダーファイルとして書き出し

## セットアップ

### 1. Xcodeでプロジェクトを開く

```bash
cd /Users/inazumimakoto/Desktop/shift/ShiftSync/ShiftSync
open ShiftSync.xcodeproj
```

### 2. Xcodeで必要な設定

1. **Signing & Capabilities** → 自分のTeamを選択
2. 配布用の **Bundle Identifier** は `com.inazumimakoto.ShiftSync` を維持
3. 以下のCapabilitiesを追加:
   - Background Modes → Background fetch を有効化
   - Keychain Sharing（オプション: Mac版と共有する場合）
   - Push Notifications（本体ターゲット）
   - App Groups（本体とウィジェットで既存のグループを共有）

最低OSはiOS 26.1。Xcode 26.1以降でアプリとウィジェットをビルドしてください。

### 3. SPMパッケージを解決

Xcode → File → Packages → Reset Package Caches

### 4. ビルド & 実行

⌘R でシミュレータまたは実機で実行

起動後は「打刻」タブからShiftWebの打刻ページを開けます。
ホーム画面に配置したウィジェットの「同期」ボタンからも同期を実行できます。

## Google Calendar連携（オプション）

1. [Google Cloud Console](https://console.cloud.google.com/) でプロジェクト作成
2. Calendar API を有効化
3. OAuth 2.0 クライアントIDを作成
4. OAuthクライアントIDとリダイレクト用URLスキームを本体の `Info.plist` に設定

Google Calendarの既存OAuth設定は変更していません。今回の `GoogleService-Info.plist` はFirebase Messaging専用です。

## 19:45退勤アラーム

- 初期値はオフ。設定または新機能紹介で有効化すると、取得済みシフトの19:45退勤分を予約します。
- 全体をオフにすると予約を取り消します。シフト単位のオフは保存され、再同期や全体設定の切替でも保持します。
- シフト取得・カレンダー同期・保存が完了した場合だけ予約を更新します。同期失敗で予約を消しません。アラーム予約の失敗は別の状態として設定画面に表示します。
- 停止済み・過去の予定は自動的に再予約しません。明示ログアウトで予約を取り消し、次のログインのシフトと混在させません。
- アラームの「退勤ページを開く」は打刻画面へ移動します。認証が切れていればログイン後に同じ画面へ戻ります。アラーム停止は打刻操作を代行しません。
- 「試しに鳴らす」はDebugビルド限定です。ReleaseとTestFlightには含まれません。
- 鳴動バナーのタイトルは「退勤時間！」とし、打刻ボタンにはカード型のアイコンを使用します。テスト用アラームも同じ見た目で表示します。見た目は予約時に保存されるため、既存予約を更新する場合は設定の全体スイッチを一度オフにしてからオンにします（日ごとの選択は保持されます）。
- 既存ユーザーの機能紹介は最初の通常起動で一度だけ表示します。新規利用の初期設定と同時に表示せず、アラームからの起動にも割り込みません。
- 機能紹介は初回設定と同じ簡潔な構成で、退勤アラームだけを案内します。権限取得済み・アラーム有効化済みでも最初の説明から表示し、その画面で「有効にする」を押してから予約結果へ進みます。Debugの設定欄で「次の起動で新機能紹介を表示」をオンにすると、未表示の状態へ戻して起動し直せます。OS権限や予約はリセットしません。
- AlarmKitにはアプリから権限を取り消す公開APIがありません。Debugの「アラームの許可設定を開く」からiPhoneのアプリ設定を開き、手動で許可をオフにして権限不足時の表示を確認できます。許可をオフにしても未確認状態には戻らず、初回の許可ダイアログは再表示されません。この導線と説明はRelease／TestFlightには含めません。
- 日ごとのアラームは設定の「予約済み」をタップして変更します。個別にオフにした日も表示し、全体オフ時は個別の選択を保持したまま操作を無効にします。「次のアラーム」は月日（MM/DD）のみ表示します。
- アラームの許可待ちは予約処理から分離しています。OSの認可呼び出しの完了が遅れても、許可状態の変更通知から続行します。応答がない場合は30秒で待ち表示を解除し、オフや画面を閉じる操作も妨げません。

## Firebase / APNsの設定と配信

Firebaseプロジェクトは `shiftsync-inazumi`、iOSアプリは既存のBundle IDで登録済みです。実際のクライアント設定を本体の `GoogleService-Info.plist` として同梱しています。Firebase Core/Messagingのみを使用し、Analyticsや配信サーバーは追加していません。

### 設定済みの内容と配布前の確認

Apple Developerの既存App IDでPush Notificationsを有効化済みです。[FirebaseのCloud Messaging設定](https://console.firebase.google.com/project/shiftsync-inazumi/settings/cloudmessaging) には、ShiftSyncのBundle IDだけを対象とする以下の認証キーを登録しています。

| 環境 | キー名 | Key ID |
| --- | --- | --- |
| Sandbox | ShiftSync FCM Sandbox | `9T32PZ6873` |
| Production | ShiftSync FCM Production | `H8B24KK62M` |

秘密鍵のローカル控えはリポジトリ外の `~/.shift_sync/apns/` に所有者のみ読み書きできる状態で保存しています。秘密鍵をリポジトリやアプリに入れないでください。

配布前に、本体のPush Notifications capabilityと署名プロファイルを更新・確認し、配布署名のAPNs環境がproductionとなることを確認してください。実機でOS通知を許可した状態でアプリを開くと、自動的にお知らせトピックへ登録します。受信・OS通知許可を取り消した後の登録停止・通知からの起動を確認します。Firebaseへのキー登録だけでは実機受信の検証は完了しません。

### 管理画面から送る

Firebase ConsoleのMessagingで通知キャンペーンを作成し、タイトル・本文を入力します。Debug端末と配布端末を分けるため、対象は以下のビルド別お知らせトピックにします。

| ビルド | トピック |
| --- | --- |
| Debug | `shiftsync-announcements-debug` |
| Release / TestFlight | `shiftsync-announcements-prod` |

Custom dataには配信ごとの `announcementID`（例：`release-1945-alarm-001`）を設定します。今回の紹介画面へ移動させる場合は `featureID` に `clock-out-alarm-v1` を指定します。未対応の機能IDや省略時は、通知本文とTestFlightへの更新案内を表示します。

### 利用者への本番配信

1. プッシュ対応を含む1.2.4（ビルド13）をXcodeでArchiveし、App Store ConnectへアップロードしてTestFlightで配布します。Gitのコミット・プッシュ・タグ作成だけではTestFlightに配布されません。
2. 利用者にはTestFlightで更新し、通知を許可した状態で一度アプリを開いてもらいます。オンラインでFCM登録と本番トピック購読が完了した端末が配信対象になります。
3. まず自分のTestFlight版で本番APNsの受信・通知タップを確認します。開発版での受信確認とは環境が異なります。
4. Firebase ConsoleのMessagingでキャンペーンを作成（既存のテストから複製も可能）し、対象トピックを `shiftsync-announcements-prod` に設定して配信します。Debug向けトピックのまま送らないでください。

1.2.3以前はFCMの登録処理がないため、このプッシュ通知で初回の更新を呼びかけることはできません。初回はTestFlightの更新案内などで周知します。一度プッシュ対応版を使い始めれば、その後のお知らせを送るたびにアプリの更新を要求する必要はありません（通知許可と有効な購読が必要です）。

お知らせ専用の紹介画面・受信トグルはありません。初期設定などで既に得たOS通知権限（許可済み・仮許可・一時的許可）に従って自動登録し、このサービスから新しい許可ダイアログは出しません。以前の独自受信設定は削除して移行します。OS通知許可の取消しを次回起動・復帰時に確認すると、既存のFCM登録を停止します。登録・停止に失敗した場合は次回起動・復帰時に再試行します。退勤アラームのオン・オフは影響しません。同期時にお知らせのローカル通知を作ることもありません。

## テスト

リポジトリ直下から、共有スキームのXCTestを実行します。

```bash
xcodebuild test -project ShiftSync/ShiftSync/ShiftSync.xcodeproj \
  -scheme ShiftSync -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:ShiftSyncTests CODE_SIGNING_ALLOWED=NO
```

予約対象・時刻変更時の引継ぎ・停止履歴・重複・アカウント分離、および偽のAlarmKitクライアントによる予約失敗／再試行／取消失敗を検証します。通知ルートの単独チェックは次で実行できます。

```bash
xcrun swiftc -swift-version 5 \
  ShiftSync/ShiftSync/Services/AppRouter.swift \
  ShiftSync/Tests/AppRoutingPolicyChecks.swift \
  -o /tmp/shiftsync-routing-checks
/tmp/shiftsync-routing-checks
```

実機ではロック中・アプリ終了時の鳴動、停止後の再同期、ログイン後の打刻復帰、ウィジェット／ショートカット同期、通知購読と解除、TestFlightの本番APNs受信を確認してください。実際の打刻ボタンはテストでは押しません。

通知タップの完了コールバックは、遷移要求の保存とともにメインスレッドで実行します。`didReceive` を `async` 版に戻すと、自動生成された完了コールバックがバックグラウンドでUIKitの状態復元処理を呼び、iOS 26.2の実機でクラッシュしたためです。通知を無視する場合（ローカル通知・破棄操作）も完了コールバックを一度実行します。回帰確認では、紹介を表示済みにしてアプリをバックグラウンドに置いた状態／終了した状態の両方で、`featureID=clock-out-alarm-v1` の通知を押し、紹介が再び開いてアプリが終了しないことを確認してください。

この修正後、iOS 26.1シミュレータで紹介表示済みの状態から、`simctl push` で受信したロック画面の通知をタップして紹介が再表示され、バックグラウンドのアプリが終了しないことを確認しました。署名付き実機ビルドとシミュレータビルド、通知ルートの単独チェックも成功しています。

同日、修正版を入れたiPhone 12（iOS 26.2）のDebugビルドでも、Firebaseから再送した通知をホーム画面からタップし、クラッシュせず紹介画面が開くことを利用者が確認しました。アプリを完全終了した状態からの通知タップとTestFlightの本番APNs受信は、別途確認が必要です。

2026-09-16時点で、XCTest 26件と通知ルートの単独チェックが成功しています。許可後もOSの要求が完了しないケース、無応答時の復帰、途中オフ、重複要求の防止を含みます。アプリ・ウィジェットのDebug／Releaseのシミュレータビルド、および署名付き実機向けビルドも成功しています。Releaseの実行ファイルにテスト用アラームや紹介状態リセットの処理・文言が含まれないことを確認しました。シミュレータでは初期設定直後に紹介を重ねないこと、次回起動での紹介、デバッグトグルでの未表示状態へのリセット、打刻への外部リンクとログイン画面への遷移を確認しています。本番APNs受信はTestFlight配布後に確認が必要です。

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
├── Widgets/
│   ├── ShiftSyncSmallWidget.swift  # 小サイズウィジェット（同期ボタン付き）
│   ├── WidgetSyncIntent.swift      # ウィジェットからの同期実行
│   └── ShiftSyncWidgetBundle.swift # ウィジェット定義
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
