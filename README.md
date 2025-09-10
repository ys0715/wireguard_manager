# WireGuard Manager

WireGuard VPNサーバーを簡単に管理するためのシェルスクリプトです。サーバーの初期化、クライアントの追加・削除、QRコード生成などの機能を備えています。

## 特徴

- 🚀 **簡単インストール**: 主要なLinuxディストリビューションに対応
- 🔒 **スプリットトンネリング**: 指定したネットワークのみをVPN経由でルーティング
- 📱 **QRコード対応**: モバイルデバイスでの設定が簡単
- 💾 **自動バックアップ**: 既存設定の安全なバックアップ
- 🛡️ **セキュリティ重視**: 適切な権限設定とキー管理
- 🔄 **動的反映**: クライアント追加時の即時反映

## 前提条件

- **OS**: Linux (Ubuntu, Debian, CentOS, Fedora, Arch Linux, openSUSE)
- **権限**: root権限（sudo）
- **インターネット接続**: サーバーのグローバルIP取得用

## インストール

```bash
git clone https://github.com/your-username/wireguard_manager.git
cd wireguard_manager
chmod +x wireguard_manager.sh
```

## 使用方法

### 1. WireGuardサーバーの初期化

```bash
sudo ./wireguard_manager.sh init [ポート番号]
```

**例:**
```bash
sudo ./wireguard_manager.sh init 51820
```

- デフォルトポート: 54321
- ポート番号を指定しない場合、デフォルトポートが使用されます

### 2. クライアントの追加

```bash
sudo ./wireguard_manager.sh add <クライアント名> <VPN-IP番号> [許可IP]
```

**例:**
```bash
# 基本的な追加（デフォルトの許可IPを使用）
sudo ./wireguard_manager.sh add client1 10

# カスタムの許可IPを指定
sudo ./wireguard_manager.sh add client2 20 "10.0.0.0/16,172.31.0.0/20"
```

**パラメータ説明:**
- `<クライアント名>`: クライアントの一意な名前
- `<VPN-IP番号>`: 1-254の数字（VPN内のIPアドレス: 10.1.0.X）
- `[許可IP]`: VPN経由でアクセスするネットワーク（デフォルト: 10.1.0.0/24,192.168.1.0/24）

### 3. クライアントの削除

```bash
sudo ./wireguard_manager.sh del <クライアント名>
```

**例:**
```bash
sudo ./wireguard_manager.sh del client1
```

### 4. クライアント一覧の表示

```bash
sudo ./wireguard_manager.sh list
```

**例:**
```bash
sudo ./wireguard_manager.sh list
```

**表示内容:**
- クライアント名
- VPN IPアドレス
- 🟢/🔴 有効/無効状態
- 設定ファイルの有無
- QRコードファイルの有無
- 鍵ファイルの有無
- 総クライアント数

### 5. 接続中クライアントの一覧表示

```bash
sudo ./wireguard_manager.sh connected
```

**例:**
```bash
sudo ./wireguard_manager.sh connected
```

**表示内容:**
- 接続中のクライアント名
- 🌐 エンドポイント（接続元IP:ポート）
- ⏰ 最終ハンドシェイク時間
- 📊 トラフィック情報（送受信バイト数）
- ⚙️ 設定状態（有効/無効）
- 🟢 接続状態
- 登録されていないピアの警告表示
- 接続中のクライアント数と総数のサマリー

### 6. クライアントの有効化

```bash
sudo ./wireguard_manager.sh enable <クライアント名>
```

**例:**
```bash
sudo ./wireguard_manager.sh enable client1
```

### 7. クライアントの無効化

```bash
sudo ./wireguard_manager.sh disable <クライアント名>
```

**例:**
```bash
sudo ./wireguard_manager.sh disable client1
```

**機能説明:**
- 無効化されたクライアントはVPN接続ができなくなります
- 設定ファイルは保持されるため、後で簡単に再有効化可能
- 即時反映：サービス実行中は自動で設定が再読み込みされます

### 8. 設定バリデーション

```bash
sudo ./wireguard_manager.sh validate
```

**例:**
```bash
sudo ./wireguard_manager.sh validate
```

**チェック項目:**
- ✅ 設定ファイルの存在と構文チェック
- ✅ サーバーキーの存在確認
- ✅ IPアドレスの重複チェック
- ✅ ポートの競合チェック
- ✅ クライアント設定ファイルの整合性確認
- ✅ ファイアウォール設定の確認
- 📊 エラー数と警告数の集計

### 9. ヘルスチェック

```bash
sudo ./wireguard_manager.sh health
```

**例:**
```bash
sudo ./wireguard_manager.sh health
```

**包括的なチェック項目:**
- 🔧 設定ファイルの検証
- ⚙️ サービス状態の確認
- 🌐 インターフェース状態の確認
- 📡 接続テストとピア状態
- 📊 トラフィック統計
- 📝 ログエラーの確認
- 💻 システムリソースの監視

### 10. 詳細統計情報の表示

```bash
sudo ./wireguard_manager.sh stats [client-name]
```

**例:**
```bash
# 全体統計を表示
sudo ./wireguard_manager.sh stats

# 個別クライアントの統計を表示
sudo ./wireguard_manager.sh stats client1
```

**全体統計表示内容:**
- 🌐 インターフェース情報（IP、MTU、ポート）
- 📊 インターフェーストラフィック統計
- 👥 クライアント統計サマリー（接続数、切断数）
- 📈 総トラフィック量と平均値
- 💻 システム情報（稼働時間、負荷平均）

**個別統計表示内容:**
- 👤 クライアント基本情報
- 🔗 接続状態とエンドポイント
- ⏰ 最終ハンドシェイクと推定接続時間
- 📊 詳細トラフィック情報（受信/送信量、比率）
- 📁 設定ファイルの状態

### 11. クライアント設定のエクスポート

```bash
sudo ./wireguard_manager.sh export <クライアント名>
```

**例:**
```bash
sudo ./wireguard_manager.sh export client1
```

**エクスポートされる内容:**
- 📁 クライアント設定ファイル (.conf)
- 🗝️ 秘密鍵ファイル (.prv)
- 🔓 公開鍵ファイル (.pub)
- 📱 QRコード画像 (.png)
- 📋 エクスポート情報ファイル
- 🌐 サーバー設定情報

### 12. クライアント設定のインポート

```bash
sudo ./wireguard_manager.sh import <設定ファイル>
```

**例:**
```bash
sudo ./wireguard_manager.sh import client1.conf
```

**インポート処理:**
- 📥 設定ファイルの検証
- 🔐 鍵ファイルの抽出と保存
- 🔧 サーバー設定への追加
- 📱 QRコードの再生成
- 🔄 設定の即時反映

### 13. 全設定のバックアップ

```bash
sudo ./wireguard_manager.sh backup
```

**例:**
```bash
sudo ./wireguard_manager.sh backup
```

**バックアップ対象:**
- 💻 サーバー設定 (/etc/wireguard/)
- 👥 クライアント設定 (~/wireguard/)
- 🔑 全鍵ファイル
- 📱 QRコード
- 📊 バックアップ情報

### 14. バックアップからの復元

```bash
sudo ./wireguard_manager.sh restore <バックアップファイル>
```

**例:**
```bash
sudo ./wireguard_manager.sh restore wireguard_backup_20241201.tar.gz
```

**復元処理:**
- 🛡️ 緊急バックアップの作成
- 🔄 サービスの停止
- 📂 設定ファイルの復元
- ✅ 設定検証
- 🚀 サービスの再起動

### 15. サービスステータスの確認

```bash
sudo ./wireguard_manager.sh status
```

**例:**
```bash
sudo ./wireguard_manager.sh status
```

**表示内容:**
- サービス状態（実行中/停止中）
- インターフェース状態
- 接続中のピア情報
- トラフィック統計
- 最新のログ

### 9. サービスの起動

```bash
sudo ./wireguard_manager.sh start
```

### 10. サービスの停止

```bash
sudo ./wireguard_manager.sh stop
```

### 11. サービスのリスタート

```bash
sudo ./wireguard_manager.sh restart
```

## 設定

### デフォルトの許可IP変更

スクリプト内の `ALLOWED_IPS` 変数を編集することで、デフォルトのスプリットトンネル設定を変更できます。

```bash
# スクリプト内の設定
ALLOWED_IPS="10.1.0.0/24,192.168.1.0/24"
```

### ファイアウォール設定

スクリプトは自動的に必要なファイアウォールルールを設定します：

- **nftables対応**: モダンなnftablesを優先使用
- **iptables互換**: nftables未対応の場合はiptablesを使用
- **NAT設定**: インターネットアクセス用のMASQUERADEルール
- **フォワーディング**: VPNクライアントからのトラフィック転送

## 生成されるファイル

```
/etc/wireguard/
├── wg0.conf              # サーバー設定ファイル
├── keys/                 # 暗号鍵ファイル
│   ├── server.prv/pub    # サーバーキー
│   └── *.prv/pub         # クライアントキー
└── scripts/              # Up/Downスクリプト
    ├── wg0-up.sh
    └── wg0-down.sh

~/wireguard/
├── conf/                 # クライアント設定ファイル
├── qrcodes/              # QRコード画像
└── backup/               # バックアップファイル
```

## トラブルシューティング

### 一般的な問題

**Q: "Error: このスクリプトは root 権限で実行する必要があります"**
- A: `sudo` を使用して実行してください

**Q: "Error: Unsupported distribution"**
- A: 対応していないディストリビューションの場合、手動で以下のツールをインストールしてください：
  - wireguard
  - wireguard-tools
  - qrencode
  - curl

**Q: "Error: failed to detect global IPv4 address"**
- A: インターネット接続を確認してください。IPv4アドレス取得用のAPIにアクセスできない場合があります

**Q: "Error: Invalid CIDR format"**
- A: 許可IPの形式が正しくありません。正しい形式: `x.x.x.x/y` (例: `10.0.0.0/16`)

### サービス管理

```bash
# サービスの状態確認（詳細情報表示）
sudo ./wireguard_manager.sh status

# サービスの起動
sudo ./wireguard_manager.sh start

# サービスの停止
sudo ./wireguard_manager.sh stop

# サービスの再起動
sudo ./wireguard_manager.sh restart

# 従来のsystemctlコマンドも使用可能
sudo systemctl status wg-quick@wg0
sudo systemctl stop wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo systemctl restart wg-quick@wg0
```

### ログの確認

```bash
# システムログ
sudo journalctl -u wg-quick@wg0

# WireGuardインターフェース情報
sudo wg show wg0
```

## セキュリティ考慮事項

- 🔐 すべての秘密鍵は適切な権限(600)で保存されます
- 🛡️ 公開鍵のみがサーバー設定に含まれます
- 🔄 定期的な鍵のローテーションを推奨します
- 📊 ログには接続情報が記録されます

## バックアップとリストア

スクリプトは自動的に既存の設定をバックアップします：

- バックアップ場所: `~/wireguard_backup/YYYYMMDD-HHMMSS/`
- リストア時はバックアップファイルを手動でコピーしてください

## 対応ディストリビューション

- ✅ Ubuntu/Debian (apt)
- ✅ CentOS/RHEL/Fedora (dnf/yum)
- ✅ Arch Linux (pacman)
- ✅ openSUSE (zypper)
- ❌ その他のディストリビューション（手動インストールが必要）

## ライセンス

このプロジェクトは MIT ライセンスの下で公開されています。

## 貢献

1. このリポジトリをフォーク
2. 機能ブランチを作成 (`git checkout -b feature/amazing-feature`)
3. 変更をコミット (`git commit -m 'Add amazing feature'`)
4. ブランチをプッシュ (`git push origin feature/amazing-feature`)
5. Pull Requestを作成

## サポート

バグ報告や機能リクエストは GitHub Issues からお願いします。
