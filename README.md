# Shift-Sync

バイト先のシフト管理システム (ShiftWeb) からシフト情報を取得し、iCloud/Googleカレンダーに自動同期し、打刻にも使えるツール群です。

## 📱 プラットフォーム

| ディレクトリ | 言語 | 説明 |
|-------------|------|------|
| `ShiftSync/` | Swift (iOS/macOS) | ネイティブアプリ版（シフト同期 + 打刻対応） |
| `shift_sync_go/` | Go | CLI版（メイン） |
| `shift_sync_py/` | Python | CLI版（プロトタイプ） |
| `shift_sync_rc/` | Rust | CLI版（実験的） |

---

## 🍎 iOS アプリ (推奨)

### 機能
- シフトの自動同期（iCloud/Googleカレンダー対応）
- ShiftWebの打刻ページ表示・打刻操作
- 変更通知（追加・更新・削除）
- オートメーション対応（ショートカット連携）
- 全履歴同期

### セットアップ
TestFlightからダウンロード: [https://testflight.apple.com/join/Cjyt88rk](https://testflight.apple.com/join/Cjyt88rk)

インストール後はアプリ内の「打刻」タブから打刻ページを開いて利用できます。

```bash
cd ShiftSync/ShiftSync
open ShiftSync.xcodeproj
```
Xcodeでビルド・実機にインストール

---

## 💻 Go CLI

### ビルド
```bash
cd shift_sync_go
go build -o shift-sync
```

### 実行
```bash
./shift-sync
```

初回実行時に対話形式でセットアップが行われます。

---

## 🐍 Python CLI

### セットアップ
```bash
cd shift_sync_py
pip install -r requirements.txt
```

### 実行
```bash
python shift_sync.py
```

---

## 📄 ライセンス

MIT License
