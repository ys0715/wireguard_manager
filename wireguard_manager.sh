#!/bin/bash
set -euo pipefail

# Root権限確認
if [[ $EUID -ne 0 ]]; then
  echo "Error: このスクリプトは root 権限で実行する必要があります。"
  echo "例: sudo $0 $*"
  exit 1
fi

USERNAME=${SUDO_USER:-$USER}
HOMEDIR=$(eval echo "~$USERNAME")

# VPN経由させたいネットワーク群（編集ポイント）
# 例: VPC全体 + RDSサブネット
#ALLOWED_IPS="10.0.0.0/16,172.31.0.0/20"
ALLOWED_IPS="10.1.0.0/24,192.168.1.0/24"

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  echo "unsupported"
}

install_dependencies() {
  echo "Checking and installing required packages..."
  
  local pm
  pm=$(detect_pkg_manager)
  
  # パッケージの存在確認
  local missing_packages=()
  
  case "$pm" in
    apt)
      if ! command -v wg >/dev/null 2>&1; then missing_packages+=("wireguard"); fi
      if ! command -v qrencode >/dev/null 2>&1; then missing_packages+=("qrencode"); fi
      if ! command -v curl >/dev/null 2>&1; then missing_packages+=("curl"); fi
      
      if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "Installing missing packages: ${missing_packages[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -y -q "${missing_packages[@]}"
      else
        echo "All required packages are already installed."
      fi
      ;;
    dnf|yum)
      if ! command -v wg >/dev/null 2>&1; then missing_packages+=("wireguard-tools"); fi
      if ! command -v qrencode >/dev/null 2>&1; then missing_packages+=("qrencode"); fi
      if ! command -v curl >/dev/null 2>&1; then missing_packages+=("curl"); fi
      
      if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "Installing missing packages: ${missing_packages[*]}"
        $pm -y install "${missing_packages[@]}" || $pm -y install wireguard qrencode curl
      else
        echo "All required packages are already installed."
      fi
      ;;
    pacman)
      if ! command -v wg >/dev/null 2>&1; then missing_packages+=("wireguard-tools"); fi
      if ! command -v qrencode >/dev/null 2>&1; then missing_packages+=("qrencode"); fi
      if ! command -v curl >/dev/null 2>&1; then missing_packages+=("curl"); fi
      
      if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "Installing missing packages: ${missing_packages[*]}"
        pacman -Sy --noconfirm --needed "${missing_packages[@]}"
      else
        echo "All required packages are already installed."
      fi
      ;;
    zypper)
      if ! command -v wg >/dev/null 2>&1; then missing_packages+=("wireguard-tools"); fi
      if ! command -v qrencode >/dev/null 2>&1; then missing_packages+=("qrencode"); fi
      if ! command -v curl >/dev/null 2>&1; then missing_packages+=("curl"); fi
      
      if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "Installing missing packages: ${missing_packages[*]}"
        zypper --non-interactive refresh
        zypper --non-interactive install --no-recommends "${missing_packages[@]}" || zypper --non-interactive install --no-recommends wireguard qrencode curl
      else
        echo "All required packages are already installed."
      fi
      ;;
    unsupported)
      echo "Error: Unsupported distribution. Please install 'wireguard', 'wireguard-tools', 'qrencode', and 'curl' manually."
      exit 1
      ;;
  esac
}

validate_cidr() {
  local cidr=$1
  # CIDR形式の基本チェック（IP/prefix）
  if ! [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    return 1
  fi

  local ip=$(echo "$cidr" | cut -d'/' -f1)
  local prefix=$(echo "$cidr" | cut -d'/' -f2)

  # プレフィックス長の範囲チェック
  if [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
    return 1
  fi

  # IPアドレスの各オクテットチェック
  IFS='.' read -ra ADDR <<< "$ip"
  for octet in "${ADDR[@]}"; do
    if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]; then
      return 1
    fi
  done

  return 0
}

usage() {
  echo "Usage:"
  echo "  $0 init [port]                             - Install & initialize WireGuard server (default port: 54321)"
  echo "  $0 add <wg-name> <vpn-ip> <allowed-ips>   - Add client (generate conf + QR)"
  echo "  $0 del <wg-name>                          - Delete client"
  echo "  $0 list                                    - List all registered clients"
  echo "  $0 connected                               - List currently connected clients"
  echo "  $0 enable <wg-name>                        - Enable client"
  echo "  $0 disable <wg-name>                       - Disable client"
  echo "  $0 validate                                - Validate WireGuard configuration"
  echo "  $0 health                                  - Comprehensive health check"
  echo "  $0 stats [client-name]                     - Show detailed statistics"
  echo "  $0 export <wg-name>                        - Export client configuration"
  echo "  $0 import <config-file>                    - Import client configuration"
  echo "  $0 backup                                  - Create full configuration backup"
  echo "  $0 restore <backup-file>                   - Restore from backup"
  echo "  $0 status                                  - Show WireGuard service status"
  echo "  $0 start                                   - Start WireGuard service"
  echo "  $0 stop                                    - Stop WireGuard service"
  echo "  $0 restart                                 - Restart WireGuard service"
  echo ""
  echo "Examples:"
  echo "  $0 init 51820                             - Initialize with port 51820"
  echo "  $0 add client1 10 \"10.0.0.0/16\""
  echo "  $0 add client2 20 \"10.0.0.0/16,172.31.0.0/20\""
  echo "  $0 list                                   - Show all clients"
  echo "  $0 connected                              - Show connected clients"
  echo "  $0 enable client1                          - Enable client1"
  echo "  $0 disable client1                         - Disable client1"
  echo "  $0 validate                               - Validate configuration"
  echo "  $0 health                                 - Full health check"
  echo "  $0 stats                                  - Show overall statistics"
  echo "  $0 stats client1                           - Show client1 statistics"
  echo "  $0 export client1                          - Export client1 config"
  echo "  $0 import client1.conf                     - Import client config"
  echo "  $0 backup                                 - Create backup"
  echo "  $0 restore backup.tar.gz                   - Restore from backup"
  echo "  $0 del client1                             - Delete client1"
  echo "  $0 status                                 - Show current status"
  echo ""
  echo "Current default AllowedIPs (split tunnel): $ALLOWED_IPS"
  exit 1
}

init_wireguard() {
  local PORT=${1:-54321}
  
  # ポート番号の検証
  if ! [[ $PORT =~ ^[0-9]+$ ]] || [ $PORT -lt 1 ] || [ $PORT -gt 65535 ]; then
    echo "Error: Invalid port number. Port must be between 1 and 65535."
    exit 1
  fi
  
  echo "=== WireGuard installation & initialization ==="
  echo "Using port: $PORT"

  BACKUP_DIR="$HOMEDIR/wireguard_backup/$(date +%Y%m%d-%H%M%S)"
  
  # 既存構成/稼働の検出 → バックアップ & 停止
  if [ -f /etc/wireguard/wg0.conf ] || ip link show wg0 >/dev/null 2>&1 || systemctl is-active --quiet wg-quick@wg0; then
    echo "Detected existing WireGuard configuration. Backing up and stopping service..."
    
    mkdir -p "$BACKUP_DIR"
    chown "$USERNAME:" "$BACKUP_DIR"
    
    # サービス停止
    systemctl stop wg-quick@wg0 || true
    systemctl disable wg-quick@wg0 || true
    
    # 既存設定をバックアップ
    if [ -d /etc/wireguard ]; then
      cp -a /etc/wireguard "$BACKUP_DIR/" 2>/dev/null || true
    fi
    if [ -d "$HOMEDIR/wireguard" ]; then
      cp -a "$HOMEDIR/wireguard" "$BACKUP_DIR/homedir_wireguard" 2>/dev/null || true
    fi
    
    echo "Backup saved to: $BACKUP_DIR"
    echo "Existing WireGuard service stopped and disabled."
  fi

  # パッケージインストール
  install_dependencies

  # 既存設定を削除して新規作成
  rm -rf /etc/wireguard
  rm -rf "$HOMEDIR/wireguard"
  
  mkdir -p /etc/wireguard/{scripts,keys}
  mkdir -p "$HOMEDIR/wireguard/conf"
  mkdir -p "$HOMEDIR/wireguard/qrcodes"
  chown -R "$USERNAME:" "$HOMEDIR/wireguard"

  # サーバーキー生成
  if [ ! -f /etc/wireguard/keys/server.prv ]; then
    wg genkey | tee /etc/wireguard/keys/server.prv | wg pubkey | tee /etc/wireguard/keys/server.pub > /dev/null
    chmod 600 /etc/wireguard/keys/server.prv
    chmod 644 /etc/wireguard/keys/server.pub
  fi
  PRIV_KEY=$(cat /etc/wireguard/keys/server.prv)

  # サーバー設定ファイル
  cat << EOL > /etc/wireguard/wg0.conf
[Interface]
Address = 10.1.0.254/24
ListenPort = ${PORT}
PrivateKey = ${PRIV_KEY}
PostUp = /etc/wireguard/scripts/wg0-up.sh
PostDown = /etc/wireguard/scripts/wg0-down.sh
EOL

  # Up/Downスクリプト（nftables 優先、iptables フォールバック）
  cat << 'EOL' > /etc/wireguard/scripts/wg0-up.sh
#!/bin/bash
set -euo pipefail
ETH=${ETH:-$(ip route get 8.8.8.8 | awk '{print $5; exit}')}

echo 1 > /proc/sys/net/ipv4/ip_forward

if command -v nft >/dev/null 2>&1; then
  # NAT は専用テーブル ip wg を用意し、postrouting で MASQUERADE
  if ! nft list table ip wg >/dev/null 2>&1; then
    nft add table ip wg
    nft add chain ip wg postrouting '{ type nat hook postrouting priority 100; policy accept; }'
  fi
  nft add rule ip wg postrouting oifname "$ETH" masquerade || true

  # フォワードは既存の inet filter/forward があればそこにルール追加、なければ iptables にフォールバック
  if nft list chain inet filter forward >/dev/null 2>&1; then
    nft add rule inet filter forward iifname "wg0" accept || true
  else
    iptables -A FORWARD -i wg0 -j ACCEPT || true
  fi
else
  # nft 不在の場合は iptables を使用
  iptables -A FORWARD -i wg0 -j ACCEPT || true
  iptables -t nat -A POSTROUTING -o $ETH -j MASQUERADE || true
fi
EOL

  cat << 'EOL' > /etc/wireguard/scripts/wg0-down.sh
#!/bin/bash
set -euo pipefail
ETH=${ETH:-$(ip route get 8.8.8.8 | awk '{print $5; exit}')}

echo 0 > /proc/sys/net/ipv4/ip_forward

if command -v nft >/dev/null 2>&1; then
  # 追加した forward ルールをハンドル番号で削除（存在すれば）
  if nft list chain inet filter forward >/dev/null 2>&1; then
    HANDLE=$(nft -a list chain inet filter forward | awk '/iifname "wg0" .* accept/ {print $NF}' | sed 's/handle //g' | tail -n1)
    if [ -n "${HANDLE:-}" ]; then
      nft delete rule inet filter forward handle "$HANDLE" || true
    fi
  fi

  # NAT 用に作成した ip wg テーブルを削除（存在すれば）
  if nft list table ip wg >/dev/null 2>&1; then
    nft delete table ip wg || true
  fi
else
  iptables -D FORWARD -i wg0 -j ACCEPT || true
  iptables -t nat -D POSTROUTING -o $ETH -j MASQUERADE || true
fi
EOL

  chmod 600 /etc/wireguard/wg0.conf
  chmod 700 /etc/wireguard/scripts/*.sh

  # サービス起動・有効化
  systemctl enable --now wg-quick@wg0
  echo "WireGuard server initialized!"
  echo "Split tunnel configured for: $ALLOWED_IPS"
  
  if [ -n "${BACKUP_DIR:-}" ] && [ -d "$BACKUP_DIR" ]; then
    echo ""
    echo "Previous configuration backed up to: $BACKUP_DIR"
    echo "You can restore it manually if needed."
  fi
}

add_client() {
  local WG_NAME=$1
  local VPN_IDX=$2
  local CLIENT_ALLOWED_IPS=${3:-$ALLOWED_IPS}

  if ! [[ $VPN_IDX =~ ^[0-9]+$ ]]; then
    echo "vpn-ip must be number."
    exit 1
  fi
  if [ $VPN_IDX -gt 254 ] || [ $VPN_IDX -lt 1 ]; then
    echo "vpn-ip must be 1-254."
    exit 1
  fi

  # ALLOWED_IPSの検証
  IFS=',' read -ra CIDRS <<< "$CLIENT_ALLOWED_IPS"
  for cidr in "${CIDRS[@]}"; do
    # 前後の空白を削除
    cidr=$(echo "$cidr" | xargs)
    if ! validate_cidr "$cidr"; then
      echo "Error: Invalid CIDR format: $cidr"
      echo "Valid format: x.x.x.x/y (e.g., 10.0.0.0/16)"
      exit 1
    fi
  done
  VPN_IP="10.1.0.$VPN_IDX"
  SERVER_IP=$(
    (curl -4s --max-time 3 https://api.ipify.org \
    || curl -4s --max-time 3 https://checkip.amazonaws.com \
    || curl -4s --max-time 3 https://ipv4.icanhazip.com \
    || dig +short -4 myip.opendns.com @resolver1.opendns.com) \
    | tr -d '\r' | head -n1
  )
  if ! [[ $SERVER_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: failed to detect global IPv4 address."
    exit 1
  fi

  if grep -q "^AllowedIPs = ${VPN_IP}/32" /etc/wireguard/wg0.conf; then
    echo "Error: ${VPN_IP} already exists."
    exit 1
  fi

  # クライアントキー生成
  wg genkey | tee /etc/wireguard/keys/${WG_NAME}.prv | wg pubkey | tee /etc/wireguard/keys/${WG_NAME}.pub > /dev/null
  chmod 600 /etc/wireguard/keys/${WG_NAME}.prv
  chmod 644 /etc/wireguard/keys/${WG_NAME}.pub

  SRV_PUB=$(cat /etc/wireguard/keys/server.pub)
  USR_PRV=$(cat /etc/wireguard/keys/${WG_NAME}.prv)
  USR_PUB=$(cat /etc/wireguard/keys/${WG_NAME}.pub)

  # サーバー設定追加
  cat << EndOfLine >> /etc/wireguard/wg0.conf

### ${WG_NAME}
[Peer]
PublicKey = ${USR_PUB}
AllowedIPs = ${VPN_IP}/32
EndOfLine

  # サーバー設定からポート番号を取得
  SERVER_PORT=$(grep "^ListenPort" /etc/wireguard/wg0.conf | cut -d' ' -f3)
  
  # クライアント設定ファイル（スプリットトンネル対応）
  CLIENT_CONF="$HOMEDIR/wireguard/conf/${WG_NAME}.conf"
  cat << EndOfLine > "$CLIENT_CONF"
[Interface]
PrivateKey = ${USR_PRV}
Address = ${VPN_IP}/24
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = ${SRV_PUB}
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepAlive = 25
EndOfLine

  chown "$USERNAME:" "$CLIENT_CONF"
  chmod 600 "$CLIENT_CONF"

  # 動的に反映
  if systemctl is-active --quiet wg-quick@wg0; then
    wg set wg0 peer ${USR_PUB} allowed-ips ${VPN_IP}/32
    echo "Client ${WG_NAME} added dynamically."
  fi

  echo "Client config saved: $CLIENT_CONF"
  echo "Split tunnel configured for: $CLIENT_ALLOWED_IPS"

  # QRコード（表示 + PNG保存）
  echo "=== QR code for ${WG_NAME} ==="
  qrencode -t ansiutf8 < "$CLIENT_CONF"

  QR_PNG="$HOMEDIR/wireguard/qrcodes/${WG_NAME}.png"
  qrencode -t png -o "$QR_PNG" < "$CLIENT_CONF"
  chown "$USERNAME:" "$QR_PNG"
  chmod 600 "$QR_PNG"

  echo "QR code saved: $QR_PNG"
}

delete_client() {
  local WG_NAME=$1
  PUBKEY=$(cat /etc/wireguard/keys/${WG_NAME}.pub 2>/dev/null || true)
  if [ -z "$PUBKEY" ]; then
    echo "No such client: $WG_NAME"
    exit 1
  fi

  if systemctl is-active --quiet wg-quick@wg0; then
    wg set wg0 peer ${PUBKEY} remove || true
    echo "Removed ${WG_NAME} from running config."
  fi

  sed -i "/^### ${WG_NAME}/,/^$/d" /etc/wireguard/wg0.conf
  rm -f /etc/wireguard/keys/${WG_NAME}.prv /etc/wireguard/keys/${WG_NAME}.pub
  rm -f "$HOMEDIR/wireguard/conf/${WG_NAME}.conf"
  rm -f "$HOMEDIR/wireguard/qrcodes/${WG_NAME}.png"

  echo "Client ${WG_NAME} deleted."
}

enable_client() {
  local WG_NAME=$1

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  # クライアントが存在するか確認
  if ! grep -q "^### ${WG_NAME}$" /etc/wireguard/wg0.conf; then
    echo "Error: Client '${WG_NAME}' not found."
    exit 1
  fi

  echo "Enabling client: ${WG_NAME}"

  # クライアントのセクションを有効化（コメントを外す）
  local temp_file=$(mktemp)
  local in_client_section=false
  local modified=false

  while IFS= read -r line; do
    if [[ $line =~ ^###\ ${WG_NAME}$ ]]; then
      # クライアントセクションの開始
      echo "$line" >> "$temp_file"
      in_client_section=true
    elif [[ $line =~ ^###\ .* ]] && [[ $in_client_section == true ]]; then
      # 次のクライアントセクションの開始
      in_client_section=false
      echo "$line" >> "$temp_file"
    elif [[ $in_client_section == true ]] && [[ $line =~ ^#\s*(\[Peer\]|\w+\s*=) ]]; then
      # コメントアウトされた行をアンコメント
      echo "${line//#}" >> "$temp_file"
      modified=true
    else
      echo "$line" >> "$temp_file"
    fi
  done < /etc/wireguard/wg0.conf

  # 変更があった場合のみファイルを更新
  if [[ $modified == true ]]; then
    mv "$temp_file" /etc/wireguard/wg0.conf
    echo "✅ Client ${WG_NAME} has been enabled."

    # サービスが実行中の場合は再読み込み
    if systemctl is-active --quiet wg-quick@wg0; then
      wg syncconf wg0 <(wg-quick strip wg0)
      echo "🔄 WireGuard configuration reloaded."
    fi
  else
    rm "$temp_file"
    echo "ℹ️  Client ${WG_NAME} is already enabled."
  fi
}

disable_client() {
  local WG_NAME=$1

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  # クライアントが存在するか確認
  if ! grep -q "^### ${WG_NAME}$" /etc/wireguard/wg0.conf; then
    echo "Error: Client '${WG_NAME}' not found."
    exit 1
  fi

  echo "Disabling client: ${WG_NAME}"

  # クライアントのセクションを無効化（コメントアウト）
  local temp_file=$(mktemp)
  local in_client_section=false
  local modified=false

  while IFS= read -r line; do
    if [[ $line =~ ^###\ ${WG_NAME}$ ]]; then
      # クライアントセクションの開始
      echo "$line" >> "$temp_file"
      in_client_section=true
    elif [[ $line =~ ^###\ .* ]] && [[ $in_client_section == true ]]; then
      # 次のクライアントセクションの開始
      in_client_section=false
      echo "$line" >> "$temp_file"
    elif [[ $in_client_section == true ]] && [[ $line =~ ^\[Peer\] ]] && [[ $line != "#"* ]]; then
      # [Peer]セクションをコメントアウト
      echo "#$line" >> "$temp_file"
      modified=true
    elif [[ $in_client_section == true ]] && [[ $line =~ ^\w+\s*= ]] && [[ $line != "#"* ]]; then
      # Peerセクション内の設定行をコメントアウト
      echo "#$line" >> "$temp_file"
      modified=true
    else
      echo "$line" >> "$temp_file"
    fi
  done < /etc/wireguard/wg0.conf

  # 変更があった場合のみファイルを更新
  if [[ $modified == true ]]; then
    mv "$temp_file" /etc/wireguard/wg0.conf
    echo "✅ Client ${WG_NAME} has been disabled."

    # サービスが実行中の場合は再読み込み
    if systemctl is-active --quiet wg-quick@wg0; then
      wg syncconf wg0 <(wg-quick strip wg0)
      echo "🔄 WireGuard configuration reloaded."
    fi
  else
    rm "$temp_file"
    echo "ℹ️  Client ${WG_NAME} is already disabled."
  fi
}

list_clients() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  echo "=== Registered WireGuard Clients ==="
  echo ""

  # サーバー設定からクライアント情報を抽出
  local client_count=0
  local current_client=""
  local client_pubkey=""
  local client_allowed_ips=""

  while IFS= read -r line; do
    # クライアントセクションの開始を検出
    if [[ $line =~ ^###\ (.+)$ ]]; then
      # 前のクライアント情報を表示
      if [ -n "$current_client" ]; then
        display_client_info "$current_client" "$client_pubkey" "$client_allowed_ips"
        ((client_count++))
      fi

      # 新しいクライアント情報を初期化
      current_client="${BASH_REMATCH[1]}"
      client_pubkey=""
      client_allowed_ips=""
    elif [[ $line =~ ^PublicKey\ =\ (.+)$ ]] && [ -n "$current_client" ]; then
      client_pubkey="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^AllowedIPs\ =\ (.+)$ ]] && [ -n "$current_client" ]; then
      client_allowed_ips="${BASH_REMATCH[1]}"
    fi
  done < /etc/wireguard/wg0.conf

  # 最後のクライアント情報を表示
  if [ -n "$current_client" ]; then
    display_client_info "$current_client" "$client_pubkey" "$client_allowed_ips"
    ((client_count++))
  fi

  echo ""
  if [ $client_count -eq 0 ]; then
    echo "No clients registered."
  else
    echo "Total: $client_count client(s)"
  fi
}

display_client_info() {
  local client_name=$1
  local pubkey=$2
  local allowed_ips=$3

  echo "Client: $client_name"
  echo "  VPN IP: $allowed_ips"

  # クライアントの有効/無効状態を確認
  if grep -A 10 "^### ${client_name}$" /etc/wireguard/wg0.conf | grep -q "^#\[Peer\]"; then
    echo "  Status: 🔴 Disabled"
  else
    echo "  Status: 🟢 Enabled"
  fi

  # クライアント設定ファイルの存在確認
  local conf_file="$HOMEDIR/wireguard/conf/${client_name}.conf"
  if [ -f "$conf_file" ]; then
    echo "  Config: $conf_file ✓"
  else
    echo "  Config: Not found ✗"
  fi

  # QRコードファイルの存在確認
  local qr_file="$HOMEDIR/wireguard/qrcodes/${client_name}.png"
  if [ -f "$qr_file" ]; then
    echo "  QR Code: $qr_file ✓"
  else
    echo "  QR Code: Not found ✗"
  fi

  # 公開鍵ファイルの存在確認
  local pubkey_file="/etc/wireguard/keys/${client_name}.pub"
  if [ -f "$pubkey_file" ]; then
    echo "  Keys: Available ✓"
  else
    echo "  Keys: Not found ✗"
  fi

  echo ""
}

validate_config() {
  echo "=== WireGuard Configuration Validation ==="
  echo ""

  local errors=0
  local warnings=0

  # 1. 設定ファイルの存在確認
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "❌ ERROR: WireGuard configuration file not found at /etc/wireguard/wg0.conf"
    echo "   Run 'init' command to initialize WireGuard server."
    return 1
  fi
  echo "✅ Configuration file exists: /etc/wireguard/wg0.conf"

  # 2. 設定ファイルの構文チェック
  if ! wg-quick check wg0 2>/dev/null; then
    echo "❌ ERROR: Configuration file has syntax errors"
    ((errors++))
  else
    echo "✅ Configuration syntax is valid"
  fi

  # 3. サーバー設定の検証
  local server_private_key="/etc/wireguard/keys/server.prv"
  local server_public_key="/etc/wireguard/keys/server.pub"

  if [ ! -f "$server_private_key" ]; then
    echo "❌ ERROR: Server private key not found: $server_private_key"
    ((errors++))
  else
    echo "✅ Server private key exists"
  fi

  if [ ! -f "$server_public_key" ]; then
    echo "❌ ERROR: Server public key not found: $server_public_key"
    ((errors++))
  else
    echo "✅ Server public key exists"
  fi

  # 4. IPアドレスの重複チェック
  declare -A used_ips
  local current_client=""
  local duplicate_ips=()

  while IFS= read -r line; do
    # クライアントセクションの開始を検出
    if [[ $line =~ ^###\ (.+)$ ]]; then
      current_client="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^AllowedIPs\ =\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      local ip="${BASH_REMATCH[1]}"
      if [[ ${used_ips[$ip]} ]]; then
        duplicate_ips+=("$ip (used by ${used_ips[$ip]} and $current_client)")
      else
        used_ips[$ip]="$current_client"
      fi
    fi
  done < /etc/wireguard/wg0.conf

  if [ ${#duplicate_ips[@]} -gt 0 ]; then
    echo "❌ ERROR: Duplicate IP addresses found:"
    for dup in "${duplicate_ips[@]}"; do
      echo "   - $dup"
    done
    ((errors++))
  else
    echo "✅ No duplicate IP addresses found"
  fi

  # 5. ポートの競合チェック
  local listen_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | cut -d' ' -f3)
  if [ -n "$listen_port" ]; then
    if netstat -tuln 2>/dev/null | grep -q ":$listen_port "; then
      echo "⚠️  WARNING: Port $listen_port is already in use by another service"
      ((warnings++))
    else
      echo "✅ Listen port $listen_port is available"
    fi
  fi

  # 6. クライアント設定ファイルの整合性チェック
  local client_count=0
  local missing_configs=()

  while IFS= read -r line; do
    if [[ $line =~ ^###\ (.+)$ ]]; then
      local client_name="${BASH_REMATCH[1]}"
      local config_file="$HOMEDIR/wireguard/conf/${client_name}.conf"
      local priv_key_file="/etc/wireguard/keys/${client_name}.prv"
      local pub_key_file="/etc/wireguard/keys/${client_name}.pub"

      ((client_count++))

      if [ ! -f "$config_file" ]; then
        missing_configs+=("$client_name: config file")
      fi
      if [ ! -f "$priv_key_file" ]; then
        missing_configs+=("$client_name: private key")
      fi
      if [ ! -f "$pub_key_file" ]; then
        missing_configs+=("$client_name: public key")
      fi
    fi
  done < /etc/wireguard/wg0.conf

  if [ ${#missing_configs[@]} -gt 0 ]; then
    echo "❌ ERROR: Missing client files:"
    for missing in "${missing_configs[@]}"; do
      echo "   - $missing"
    done
    ((errors++))
  else
    echo "✅ All client configuration files exist"
  fi

  # 7. ファイアウォール設定の確認
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
      if [ -n "$listen_port" ] && ! ufw status 2>/dev/null | grep -q "$listen_port"; then
        echo "⚠️  WARNING: UFW is active but WireGuard port $listen_port is not allowed"
        ((warnings++))
      else
        echo "✅ Firewall (UFW) configuration looks good"
      fi
    fi
  elif command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
      echo "ℹ️  FirewallD is active - manual port configuration may be required"
    fi
  fi

  # 結果表示
  echo ""
  echo "=== Validation Results ==="
  echo "Clients found: $client_count"
  if [ $errors -gt 0 ]; then
    echo "❌ Errors: $errors"
  else
    echo "✅ Errors: 0"
  fi
  if [ $warnings -gt 0 ]; then
    echo "⚠️  Warnings: $warnings"
  else
    echo "✅ Warnings: 0"
  fi

  if [ $errors -gt 0 ]; then
    echo ""
    echo "🔧 Fix the errors above before using WireGuard."
    return 1
  else
    echo ""
    echo "🎉 Configuration validation passed!"
    return 0
  fi
}

health_check() {
  echo "=== WireGuard Health Check ==="
  echo ""

  local issues=0

  # 1. 基本的な設定検証を実行
  if ! validate_config >/dev/null 2>&1; then
    echo "❌ CRITICAL: Configuration validation failed"
    ((issues++))
  else
    echo "✅ Configuration validation passed"
  fi

  # 2. サービス状態の確認
  if systemctl is-active --quiet wg-quick@wg0; then
    echo "✅ WireGuard service is running"
  else
    echo "❌ CRITICAL: WireGuard service is not running"
    ((issues++))
  fi

  # 3. インターフェース状態の確認
  if ip link show wg0 >/dev/null 2>&1; then
    echo "✅ WireGuard interface wg0 exists"

    local wg_ip=$(ip addr show wg0 | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    if [ -n "$wg_ip" ]; then
      echo "✅ Interface has IP address: $wg_ip"
    else
      echo "❌ ERROR: Interface wg0 has no IP address"
      ((issues++))
    fi
  else
    echo "❌ CRITICAL: WireGuard interface wg0 does not exist"
    ((issues++))
  fi

  # 4. 接続テスト
  if command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    local peer_count=$(wg show wg0 peers | wc -l)
    echo "ℹ️  Configured peers: $peer_count"

    # 最近のハンドシェイクがあるピアの数をカウント
    local active_peers=0
    while IFS= read -r peer; do
      if [ -n "$peer" ]; then
        local handshake=$(wg show wg0 peer "$peer" 2>/dev/null | grep "latest handshake" | sed 's/.*latest handshake: //' | sed 's/ ago//')
        if [ -n "$handshake" ]; then
          # 24時間以内のハンドシェイクをアクティブとみなす
          if [[ $handshake == *"second"* ]] || [[ $handshake == *"minute"* ]] || [[ $handshake == *"hour"* ]]; then
            ((active_peers++))
          fi
        fi
      fi
    done <<< "$(wg show wg0 peers 2>/dev/null)"

    echo "ℹ️  Recently active peers (24h): $active_peers"
  fi

  # 5. リソース使用状況の確認
  if ip link show wg0 >/dev/null 2>&1; then
    local rx_bytes=$(ip -s link show wg0 | grep -A1 "RX:" | tail -n1 | awk '{print $1}')
    local tx_bytes=$(ip -s link show wg0 | grep -A1 "TX:" | tail -n1 | awk '{print $1}')

    if [ -n "$rx_bytes" ] && [ -n "$tx_bytes" ]; then
      echo "📊 Traffic: RX $(numfmt --to=iec-i --suffix=B $rx_bytes 2>/dev/null || echo "${rx_bytes}B"), TX $(numfmt --to=iec-i --suffix=B $tx_bytes 2>/dev/null || echo "${tx_bytes}B")"
    fi
  fi

  # 6. ログエラーの確認
  if command -v journalctl >/dev/null 2>&1; then
    local error_count=$(journalctl -u wg-quick@wg0 --since "1 hour ago" -q 2>/dev/null | grep -i "error\|failed\|fail" | wc -l)
    if [ "$error_count" -gt 0 ]; then
      echo "⚠️  Recent errors in logs: $error_count"
      ((issues++))
    else
      echo "✅ No recent errors in service logs"
    fi
  fi

  # 7. システムリソースの確認
  local mem_usage=$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100.0}')
  local cpu_load=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d',' -f1 | xargs)

  echo "🖥️  System: CPU load $cpu_load, Memory ${mem_usage}%"

  if (( $(echo "$mem_usage > 90" | bc -l 2>/dev/null || echo "0") )); then
    echo "⚠️  WARNING: High memory usage detected"
    ((issues++))
  fi

  if (( $(echo "$cpu_load > $(nproc)" | bc -l 2>/dev/null || echo "0") )); then
    echo "⚠️  WARNING: High CPU load detected"
    ((issues++))
  fi

  # 結果表示
  echo ""
  echo "=== Health Check Results ==="
  if [ $issues -gt 0 ]; then
    echo "❌ Issues found: $issues"
    echo ""
    echo "🔧 Address the issues above to ensure optimal WireGuard performance."
    return 1
  else
    echo "🎉 All health checks passed!"
    return 0
  fi
}

list_connected_clients() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  echo "=== Currently Connected WireGuard Clients ==="
  echo ""

  # クライアント名と公開鍵のマッピングを取得
  declare -A client_map
  declare -A client_ips

  local current_client=""
  local client_pubkey=""
  local client_allowed_ips=""

  while IFS= read -r line; do
    # クライアントセクションの開始を検出
    if [[ $line =~ ^###\ (.+)$ ]]; then
      # 前のクライアント情報を保存
      if [ -n "$current_client" ] && [ -n "$client_pubkey" ]; then
        client_map["$client_pubkey"]="$current_client"
        client_ips["$client_pubkey"]="$client_allowed_ips"
      fi

      # 新しいクライアント情報を初期化
      current_client="${BASH_REMATCH[1]}"
      client_pubkey=""
      client_allowed_ips=""
    elif [[ $line =~ ^PublicKey\ =\ (.+)$ ]] && [ -n "$current_client" ]; then
      client_pubkey="${BASH_REMATCH[1]}"
    elif [[ $line =~ ^AllowedIPs\ =\ (.+)$ ]] && [ -n "$current_client" ]; then
      client_allowed_ips="${BASH_REMATCH[1]}"
    fi
  done < /etc/wireguard/wg0.conf

  # 最後のクライアント情報を保存
  if [ -n "$current_client" ] && [ -n "$client_pubkey" ]; then
    client_map["$client_pubkey"]="$current_client"
    client_ips["$client_pubkey"]="$client_allowed_ips"
  fi

  # 接続中のピアを取得して表示
  if command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    local connected_count=0
    local total_peers=0

    # すべてのピアを取得
    while IFS= read -r peer_pubkey; do
      if [ -n "$peer_pubkey" ]; then
        ((total_peers++))
        local client_name="${client_map[$peer_pubkey]}"
        local client_ip="${client_ips[$peer_pubkey]}"

        if [ -n "$client_name" ]; then
          echo "Client: $client_name"
          echo "  VPN IP: $client_ip"

          # クライアントの設定状態を確認
          if grep -A 10 "^### ${client_name}$" /etc/wireguard/wg0.conf | grep -q "^#\[Peer\]"; then
            echo "  ⚙️  Config Status: 🔴 Disabled"
          else
            echo "  ⚙️  Config Status: 🟢 Enabled"
          fi

          # ピアの詳細情報を取得
          local peer_info=$(wg show wg0 peer "$peer_pubkey" 2>/dev/null)
          if [ $? -eq 0 ] && [ -n "$peer_info" ]; then
            # エンドポイントを取得
            local endpoint=$(echo "$peer_info" | grep "endpoint:" | sed 's/.*endpoint: //' | sed 's/ //g')
            if [ -n "$endpoint" ]; then
              echo "  🌐 Endpoint: $endpoint"
            fi

            # 最終ハンドシェイク時間を取得
            local handshake=$(echo "$peer_info" | grep "latest handshake:" | sed 's/.*latest handshake: //' | sed 's/ //g')
            if [ -n "$handshake" ]; then
              echo "  ⏰ Last Handshake: $handshake ago"
            fi

            # トラフィック情報を取得
            local transfer=$(echo "$peer_info" | grep "transfer:" | sed 's/.*transfer: //' | sed 's/ //g')
            if [ -n "$transfer" ]; then
              echo "  📊 Transfer: $transfer"
            fi

            echo "  🟢 Connection Status: Connected"
            ((connected_count++))
          else
            echo "  🔴 Connection Status: Disconnected"
          fi
        else
          # 登録されていないピアの場合
          echo "Unknown Peer: ${peer_pubkey:0:16}..."
          local peer_info=$(wg show wg0 peer "$peer_pubkey" 2>/dev/null)
          if [ $? -eq 0 ] && [ -n "$peer_info" ]; then
            local endpoint=$(echo "$peer_info" | grep "endpoint:" | sed 's/.*endpoint: //' | sed 's/ //g')
            if [ -n "$endpoint" ]; then
              echo "  🌐 Endpoint: $endpoint"
              echo "  ⚠️  Status: Connected (unregistered peer)"
              ((connected_count++))
            fi
          fi
        fi
        echo ""
      fi
    done <<< "$(wg show wg0 peers 2>/dev/null)"

    echo "=== Summary ==="
    echo "Connected clients: $connected_count"
    echo "Total registered clients: ${#client_map[@]}"
    echo "Total peers in config: $total_peers"
  else
    echo "❌ WireGuard interface is not active or wg command not available."
    echo "   Run 'status' command to check service state."
  fi
}

show_stats() {
  local client_name=$1

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  if [ -n "$client_name" ]; then
    # 個別クライアントの統計を表示
    show_client_stats "$client_name"
  else
    # 全体統計を表示
    show_overall_stats
  fi
}

show_overall_stats() {
  echo "=== WireGuard Overall Statistics ==="
  echo ""

  if ! ip link show wg0 >/dev/null 2>&1; then
    echo "❌ WireGuard interface is not active."
    return 1
  fi

  # インターフェースの基本情報
  local wg_ip=$(ip addr show wg0 | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
  local mtu=$(ip link show wg0 | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
  local listen_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | cut -d' ' -f3)

  echo "🌐 Interface Information:"
  echo "   IP Address: $wg_ip"
  echo "   MTU: $mtu"
  echo "   Listen Port: ${listen_port:-Unknown}"
  echo ""

  # インターフェースのトラフィック統計
  if command -v ip >/dev/null 2>&1; then
    echo "📊 Interface Traffic Statistics:"
    local rx_bytes=$(ip -s link show wg0 | grep "RX:" | tail -n1 | awk '{print $1}')
    local tx_bytes=$(ip -s link show wg0 | grep "TX:" | tail -n1 | awk '{print $1}')

    if [ -n "$rx_bytes" ] && [ -n "$tx_bytes" ]; then
      echo "   Received: $(numfmt --to=iec-i --suffix=B $rx_bytes 2>/dev/null || echo "${rx_bytes}B")"
      echo "   Sent: $(numfmt --to=iec-i --suffix=B $tx_bytes 2>/dev/null || echo "${tx_bytes}B")"
      echo "   Total: $(numfmt --to=iec-i --suffix=B $((rx_bytes + tx_bytes)) 2>/dev/null || echo "$((rx_bytes + tx_bytes))B")"
    fi
    echo ""
  fi

  # クライアント統計の集計
  if command -v wg >/dev/null 2>&1; then
    echo "👥 Client Statistics Summary:"
    local total_clients=0
    local connected_clients=0
    local total_rx=0
    local total_tx=0

    # クライアント名と公開鍵のマッピングを取得
    declare -A client_map
    local current_client=""
    while IFS= read -r line; do
      if [[ $line =~ ^###\ (.+)$ ]]; then
        current_client="${BASH_REMATCH[1]}"
      elif [[ $line =~ ^PublicKey\ =\ (.+)$ ]] && [ -n "$current_client" ]; then
        client_map["${BASH_REMATCH[1]}"]="$current_client"
      fi
    done < /etc/wireguard/wg0.conf

    total_clients=${#client_map[@]}

    # 各ピアの統計を集計
    while IFS= read -r peer; do
      if [ -n "$peer" ]; then
        local peer_info=$(wg show wg0 peer "$peer" 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$peer_info" ]; then
          # トラフィック情報を取得
          local rx_line=$(echo "$peer_info" | grep "transfer:" | sed 's/.*transfer: //' | sed 's/ received.*//')
          local tx_line=$(echo "$peer_info" | grep "transfer:" | sed 's/.*transfer: //' | sed 's/.*received, //' | sed 's/ sent.*//')

          if [ -n "$rx_line" ]; then
            # 数値のみを抽出（例: "1.23 MiB" -> "1230000")
            local rx_bytes=$(echo "$rx_line" | sed 's/[^0-9.]*//g')
            local rx_unit=$(echo "$rx_line" | sed 's/[0-9.]*//g' | tr -d ' ')
            total_rx=$((total_rx + $(convert_to_bytes "$rx_bytes" "$rx_unit")))
          fi

          if [ -n "$tx_line" ]; then
            local tx_bytes=$(echo "$tx_line" | sed 's/[^0-9.]*//g')
            local tx_unit=$(echo "$tx_line" | sed 's/[0-9.]*//g' | tr -d ' ')
            total_tx=$((total_tx + $(convert_to_bytes "$tx_bytes" "$tx_unit")))
          fi

          ((connected_clients++))
        fi
      fi
    done <<< "$(wg show wg0 peers 2>/dev/null)"

    echo "   Total Clients: $total_clients"
    echo "   Connected Clients: $connected_clients"
    echo "   Disconnected Clients: $((total_clients - connected_clients))"
    echo ""

    if [ $connected_clients -gt 0 ]; then
      echo "📈 Total Client Traffic:"
      echo "   Total Received: $(bytes_to_human $total_rx)"
      echo "   Total Sent: $(bytes_to_human $total_tx)"
      echo "   Total Traffic: $(bytes_to_human $((total_rx + total_tx)))"
      echo ""

      echo "📊 Per-Client Average:"
      echo "   Average Received: $(bytes_to_human $((total_rx / connected_clients)))"
      echo "   Average Sent: $(bytes_to_human $((total_tx / connected_clients)))"
    fi
  fi

  # システム情報
  echo ""
  echo "💻 System Information:"
  local uptime=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
  local load_avg=$(uptime | awk -F'load average:' '{print $2}' | cut -d',' -f1 | xargs)
  echo "   System Uptime: ${uptime:-Unknown}"
  echo "   Load Average: ${load_avg:-Unknown}"

  # WireGuardサービスの稼働時間
  if systemctl is-active --quiet wg-quick@wg0; then
    local service_uptime=$(systemctl show wg-quick@wg0 -p ActiveEnterTimestamp | cut -d'=' -f2)
    if [ -n "$service_uptime" ]; then
      echo "   WireGuard Service Uptime: $(date -d "$service_uptime" '+%Y-%m-%d %H:%M:%S')"
    fi
  fi
}

show_client_stats() {
  local client_name=$1

  echo "=== Statistics for Client: $client_name ==="
  echo ""

  # クライアントが存在するか確認
  if ! grep -q "^### ${client_name}$" /etc/wireguard/wg0.conf; then
    echo "❌ Error: Client '$client_name' not found."
    return 1
  fi

  # クライアントの設定情報を取得
  local client_pubkey=""
  local client_ip=""
  local client_allowed_ips=""

  local in_client_section=false
  while IFS= read -r line; do
    if [[ $line =~ ^###\ ${client_name}$ ]]; then
      in_client_section=true
    elif [[ $line =~ ^###\ .* ]] && [[ $in_client_section == true ]]; then
      break
    elif [[ $in_client_section == true ]]; then
      if [[ $line =~ ^PublicKey\ =\ (.+)$ ]]; then
        client_pubkey="${BASH_REMATCH[1]}"
      elif [[ $line =~ ^AllowedIPs\ =\ (.+)$ ]]; then
        client_ip="${BASH_REMATCH[1]}"
        client_allowed_ips="$line"
      fi
    fi
  done < /etc/wireguard/wg0.conf

  # 基本情報表示
  echo "👤 Client Information:"
  echo "   Name: $client_name"
  echo "   VPN IP: ${client_ip:-Unknown}"
  echo "   Public Key: ${client_pubkey:0:16}..."
  echo ""

  # WireGuardピア情報を取得
  if [ -n "$client_pubkey" ] && command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    local peer_info=$(wg show wg0 peer "$client_pubkey" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$peer_info" ]; then
      echo "🔗 Connection Status: Connected"
      echo ""

      # エンドポイント情報
      local endpoint=$(echo "$peer_info" | grep "endpoint:" | sed 's/.*endpoint: //' | sed 's/ //g')
      if [ -n "$endpoint" ]; then
        echo "🌐 Endpoint: $endpoint"
      fi

      # 最終ハンドシェイク
      local handshake=$(echo "$peer_info" | grep "latest handshake:" | sed 's/.*latest handshake: //' | sed 's/ //g')
      if [ -n "$handshake" ]; then
        echo "⏰ Last Handshake: $handshake ago"

        # 接続時間の計算（概算）
        local connection_time=""
        if [[ $handshake == *"second"* ]]; then
          local seconds=$(echo "$handshake" | sed 's/[^0-9]*//g')
          if [ "$seconds" -lt 3600 ]; then
            connection_time="~${seconds}s"
          else
            connection_time="~$((seconds / 3600))h"
          fi
        elif [[ $handshake == *"minute"* ]]; then
          local minutes=$(echo "$handshake" | sed 's/[^0-9]*//g')
          connection_time="~${minutes}m"
        elif [[ $handshake == *"hour"* ]]; then
          local hours=$(echo "$handshake" | sed 's/[^0-9]*//g')
          connection_time="~${hours}h"
        fi
        if [ -n "$connection_time" ]; then
          echo "   Estimated Connection Time: $connection_time"
        fi
      fi
      echo ""

      # トラフィック情報
      local transfer_line=$(echo "$peer_info" | grep "transfer:")
      if [ -n "$transfer_line" ]; then
        echo "📊 Traffic Statistics:"
        echo "   $transfer_line"

        # 詳細なトラフィック分析
        local rx_info=$(echo "$transfer_line" | sed 's/.*transfer: //' | sed 's/ received.*//')
        local tx_info=$(echo "$transfer_line" | sed 's/.*transfer: //' | sed 's/.*received, //' | sed 's/ sent.*//')

        if [ -n "$rx_info" ] && [ -n "$tx_info" ]; then
          local rx_bytes=$(echo "$rx_info" | sed 's/[^0-9.]*//g')
          local rx_unit=$(echo "$rx_info" | sed 's/[0-9.]*//g' | tr -d ' ')
          local tx_bytes=$(echo "$tx_info" | sed 's/[^0-9.]*//g')
          local tx_unit=$(echo "$tx_info" | sed 's/[0-9.]*//g' | tr -d ' ')

          local rx_bytes_num=$(convert_to_bytes "$rx_bytes" "$rx_unit")
          local tx_bytes_num=$(convert_to_bytes "$tx_bytes" "$tx_unit")

          echo ""
          echo "📈 Detailed Traffic Analysis:"
          echo "   Data Received: $(bytes_to_human $rx_bytes_num)"
          echo "   Data Sent: $(bytes_to_human $tx_bytes_num)"
          echo "   Total Traffic: $(bytes_to_human $((rx_bytes_num + tx_bytes_num)))"

          # 通信比率の計算
          if [ $((rx_bytes_num + tx_bytes_num)) -gt 0 ]; then
            local rx_ratio=$((rx_bytes_num * 100 / (rx_bytes_num + tx_bytes_num)))
            local tx_ratio=$((tx_bytes_num * 100 / (rx_bytes_num + tx_bytes_num)))
            echo "   Traffic Ratio: ${rx_ratio}% RX, ${tx_ratio}% TX"
          fi
        fi
      fi
    else
      echo "🔴 Connection Status: Disconnected"
      echo ""
      echo "ℹ️  Client is configured but not currently connected."
    fi
  else
    echo "❌ Cannot retrieve WireGuard statistics."
    echo "   Make sure WireGuard is running and interface is active."
  fi

  # 設定ファイル情報
  echo ""
  echo "📁 Configuration Files:"
  local config_file="$HOMEDIR/wireguard/conf/${client_name}.conf"
  local qr_file="$HOMEDIR/wireguard/qrcodes/${client_name}.png"

  if [ -f "$config_file" ]; then
    local config_size=$(stat -c%s "$config_file" 2>/dev/null || echo "0")
    echo "   ✅ Config file: $config_file ($(bytes_to_human $config_size))"
  else
    echo "   ❌ Config file: Not found"
  fi

  if [ -f "$qr_file" ]; then
    local qr_size=$(stat -c%s "$qr_file" 2>/dev/null || echo "0")
    echo "   ✅ QR code: $qr_file ($(bytes_to_human $qr_size))"
  else
    echo "   ❌ QR code: Not found"
  fi

  # 鍵ファイル情報
  local priv_key_file="/etc/wireguard/keys/${client_name}.prv"
  local pub_key_file="/etc/wireguard/keys/${client_name}.pub"

  if [ -f "$priv_key_file" ] && [ -f "$pub_key_file" ]; then
    echo "   ✅ Key files: Available"
  else
    echo "   ❌ Key files: Missing"
  fi
}

convert_to_bytes() {
  local value=$1
  local unit=$2

  # 小数点を含む数値を整数に変換
  local int_value=$(echo "$value" | awk '{print int($1)}')

  case $unit in
    "B") echo $int_value ;;
    "KiB"|"KB") echo $((int_value * 1024)) ;;
    "MiB"|"MB") echo $((int_value * 1024 * 1024)) ;;
    "GiB"|"GB") echo $((int_value * 1024 * 1024 * 1024)) ;;
    "TiB"|"TB") echo $((int_value * 1024 * 1024 * 1024 * 1024)) ;;
    *) echo $int_value ;;  # 単位が不明な場合はそのまま
  esac
}

bytes_to_human() {
  local bytes=$1

  if [ $bytes -ge $((1024 * 1024 * 1024 * 1024)) ]; then
    echo "$((bytes / (1024 * 1024 * 1024 * 1024))) TiB"
  elif [ $bytes -ge $((1024 * 1024 * 1024)) ]; then
    echo "$((bytes / (1024 * 1024 * 1024))) GiB"
  elif [ $bytes -ge $((1024 * 1024)) ]; then
    echo "$((bytes / (1024 * 1024))) MiB"
  elif [ $bytes -ge 1024 ]; then
    echo "$((bytes / 1024)) KiB"
  else
    echo "${bytes} B"
  fi
}

export_client() {
  local client_name=$1

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  # クライアントが存在するか確認
  if ! grep -q "^### ${client_name}$" /etc/wireguard/wg0.conf; then
    echo "❌ Error: Client '$client_name' not found."
    exit 1
  fi

  echo "📤 Exporting client configuration: ${client_name}"

  # エクスポートディレクトリの作成
  local export_dir="$HOMEDIR/wireguard_exports"
  mkdir -p "$export_dir"

  # タイムスタンプ付きのエクスポートファイル名
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local export_file="$export_dir/${client_name}_export_${timestamp}.tar.gz"

  # 一時ディレクトリを作成
  local temp_dir=$(mktemp -d)
  local client_dir="$temp_dir/$client_name"
  mkdir -p "$client_dir"

  # クライアントの設定情報を収集
  local client_pubkey=""
  local client_ip=""
  local client_allowed_ips=""

  local in_client_section=false
  while IFS= read -r line; do
    if [[ $line =~ ^###\ ${client_name}$ ]]; then
      in_client_section=true
    elif [[ $line =~ ^###\ .* ]] && [[ $in_client_section == true ]]; then
      break
    elif [[ $in_client_section == true ]]; then
      if [[ $line =~ ^PublicKey\ =\ (.+)$ ]]; then
        client_pubkey="${BASH_REMATCH[1]}"
      elif [[ $line =~ ^AllowedIPs\ =\ (.+)$ ]]; then
        client_ip="${BASH_REMATCH[1]}"
        client_allowed_ips="$line"
      fi
    fi
  done < /etc/wireguard/wg0.conf

  # エクスポート情報ファイルの作成
  cat > "$client_dir/export_info.txt" << EOF
WireGuard Client Export Information
===================================
Client Name: $client_name
Export Date: $(date)
Server: $(hostname)

Configuration:
- VPN IP: $client_ip
- Public Key: ${client_pubkey:0:16}...
- Allowed IPs: ${client_allowed_ips#AllowedIPs = }
EOF

  # クライアント設定ファイルのコピー
  local config_file="$HOMEDIR/wireguard/conf/${client_name}.conf"
  if [ -f "$config_file" ]; then
    cp "$config_file" "$client_dir/"
    echo "✅ Client configuration file copied"
  else
    echo "⚠️  Client configuration file not found"
  fi

  # QRコードファイルのコピー
  local qr_file="$HOMEDIR/wireguard/qrcodes/${client_name}.png"
  if [ -f "$qr_file" ]; then
    cp "$qr_file" "$client_dir/"
    echo "✅ QR code file copied"
  else
    echo "⚠️  QR code file not found"
  fi

  # 秘密鍵ファイルのコピー（注意喚起）
  local priv_key_file="/etc/wireguard/keys/${client_name}.prv"
  if [ -f "$priv_key_file" ]; then
    cp "$priv_key_file" "$client_dir/"
    echo "⚠️  Private key file copied (handle with care!)"
  else
    echo "❌ Private key file not found"
  fi

  # 公開鍵ファイルのコピー
  local pub_key_file="/etc/wireguard/keys/${client_name}.pub"
  if [ -f "$pub_key_file" ]; then
    cp "$pub_key_file" "$client_dir/"
    echo "✅ Public key file copied"
  fi

  # サーバー設定の一部をエクスポート（クライアントが必要とする情報のみ）
  local server_config="$client_dir/server_info.txt"
  if [ -f /etc/wireguard/wg0.conf ]; then
    grep "^ListenPort\|^Address\|^PrivateKey" /etc/wireguard/wg0.conf > "$server_config" 2>/dev/null || true
    if [ -s "$server_config" ]; then
      echo "✅ Server configuration info exported"
    fi
  fi

  # アーカイブの作成
  cd "$temp_dir" && tar -czf "$export_file" "$client_name" 2>/dev/null

  if [ $? -eq 0 ]; then
    echo "✅ Client configuration exported successfully!"
    echo "📁 Export file: $export_file"
    echo "📊 File size: $(stat -c%s "$export_file" 2>/dev/null | xargs -I {} echo "scale=2; {}/1024/1024" | bc 2>/dev/null || echo "unknown") MB"
  else
    echo "❌ Failed to create export archive"
    rm -f "$export_file"
    exit 1
  fi

  # 一時ディレクトリの削除
  rm -rf "$temp_dir"

  # 適切な権限設定
  chown "$USERNAME:" "$export_file" 2>/dev/null || true
  chmod 600 "$export_file"

  echo ""
  echo "🔐 Security Notice:"
  echo "   - Keep the export file secure as it contains private keys"
  echo "   - Share only with authorized personnel"
  echo "   - Consider password-protecting the archive"
}

import_client() {
  local config_file=$1

  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  if [ ! -f "$config_file" ]; then
    echo "❌ Error: Configuration file '$config_file' not found."
    exit 1
  fi

  echo "📥 Importing client configuration from: $config_file"

  # 設定ファイルの内容を確認
  if ! grep -q "\[Interface\]" "$config_file" || ! grep -q "\[Peer\]" "$config_file"; then
    echo "❌ Error: Invalid WireGuard configuration file format."
    echo "   File must contain both [Interface] and [Peer] sections."
    exit 1
  fi

  # クライアント名をファイル名から推測、またはインターフェースセクションから取得
  local client_name=""
  if [[ "$config_file" =~ /([^/]+)\.conf$ ]]; then
    client_name="${BASH_REMATCH[1]}"
  elif [[ "$config_file" =~ ([^/]+)$ ]]; then
    client_name="${BASH_REMATCH[1]%.conf}"
  fi

  # インターフェースセクションからクライアント名を取得（Addressから）
  local address_line=$(grep "^Address" "$config_file" | head -n1)
  if [[ $address_line =~ Address\s*=\s*([0-9]+\.[0-9]+\.[0-9]+\.)[0-9]+ ]]; then
    local ip_prefix="${BASH_REMATCH[1]}"
    # IPアドレスの最後の一桁からクライアント名を推測
    local last_octet=$(grep "^Address" "$config_file" | sed 's/.*\.//' | sed 's/\/.*//')
    if [ -n "$last_octet" ] && [ "$last_octet" -ge 1 ] && [ "$last_octet" -le 254 ]; then
      client_name="client${last_octet}"
    fi
  fi

  if [ -z "$client_name" ]; then
    echo "❌ Error: Could not determine client name from configuration file."
    echo "   Please specify a client name or ensure the config file has a proper Address field."
    exit 1
  fi

  # クライアントが既に存在するか確認
  if grep -q "^### ${client_name}$" /etc/wireguard/wg0.conf; then
    echo "⚠️  Warning: Client '$client_name' already exists."
    read -p "   Do you want to overwrite? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Import cancelled."
      exit 0
    fi
  fi

  echo "🔄 Importing as client: $client_name"

  # 秘密鍵の抽出と保存
  local private_key=$(grep "^PrivateKey" "$config_file" | sed 's/.*= //' | tr -d ' ')
  if [ -n "$private_key" ]; then
    echo "$private_key" > "/etc/wireguard/keys/${client_name}.prv"
    chmod 600 "/etc/wireguard/keys/${client_name}.prv"
    echo "✅ Private key saved"
  else
    echo "❌ Error: No private key found in configuration file"
    exit 1
  fi

  # 公開鍵の生成と保存
  if command -v wg >/dev/null 2>&1; then
    local public_key=$(echo "$private_key" | wg pubkey)
    if [ -n "$public_key" ]; then
      echo "$public_key" > "/etc/wireguard/keys/${client_name}.pub"
      chmod 644 "/etc/wireguard/keys/${client_name}.pub"
      echo "✅ Public key generated and saved"
    fi
  fi

  # クライアント設定ファイルの保存
  cp "$config_file" "$HOMEDIR/wireguard/conf/${client_name}.conf"
  chown "$USERNAME:" "$HOMEDIR/wireguard/conf/${client_name}.conf" 2>/dev/null || true
  chmod 600 "$HOMEDIR/wireguard/conf/${client_name}.conf"

  # VPN IPアドレスの取得
  local vpn_ip=""
  if [[ $address_line =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
    vpn_ip="${BASH_REMATCH[1]}"
  fi

  # サーバー設定ファイルへの追加
  local server_pubkey=$(cat /etc/wireguard/keys/server.pub 2>/dev/null)
  local server_endpoint=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname -I | awk '{print $1}')
  local server_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | cut -d' ' -f3)

  # 既存のクライアント設定を削除（上書きの場合）
  sed -i "/^### ${client_name}/,/^$/d" /etc/wireguard/wg0.conf

  # 新しいクライアント設定の追加
  cat >> /etc/wireguard/wg0.conf << EOF

### ${client_name}
[Peer]
PublicKey = ${public_key}
AllowedIPs = ${vpn_ip}/32
EOF

  echo "✅ Client configuration added to server"

  # QRコードの生成
  if command -v qrencode >/dev/null 2>&1; then
    local qr_file="$HOMEDIR/wireguard/qrcodes/${client_name}.png"
    qrencode -t png -o "$qr_file" < "$HOMEDIR/wireguard/conf/${client_name}.conf"
    chown "$USERNAME:" "$qr_file" 2>/dev/null || true
    chmod 600 "$qr_file"
    echo "✅ QR code generated"
  fi

  # 設定の再読み込み
  if systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || true
    echo "🔄 WireGuard configuration reloaded"
  fi

  echo "✅ Client '$client_name' imported successfully!"
  echo "   Configuration: $HOMEDIR/wireguard/conf/${client_name}.conf"
  if [ -f "$qr_file" ]; then
    echo "   QR Code: $qr_file"
  fi
}

backup_config() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  echo "💾 Creating full WireGuard configuration backup..."

  # バックアップディレクトリの作成
  local backup_dir="$HOMEDIR/wireguard_backups"
  mkdir -p "$backup_dir"

  # タイムスタンプ付きのバックアップファイル名
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$backup_dir/wireguard_backup_${timestamp}.tar.gz"

  # 一時ディレクトリを作成
  local temp_dir=$(mktemp -d)
  local backup_temp_dir="$temp_dir/wireguard_backup"
  mkdir -p "$backup_temp_dir"

  # バックアップ情報ファイルの作成
  cat > "$backup_temp_dir/backup_info.txt" << EOF
WireGuard Configuration Backup
==============================
Backup Date: $(date)
Server: $(hostname)
WireGuard Status: $(systemctl is-active wg-quick@wg0 2>/dev/null || echo "unknown")

This backup contains:
- Server configuration (/etc/wireguard/)
- Client configurations ($HOMEDIR/wireguard/)
- All keys and certificates
- QR codes for mobile devices

To restore, use: $0 restore $backup_file
EOF

  # サーバー設定のコピー
  if [ -d /etc/wireguard ]; then
    cp -r /etc/wireguard "$backup_temp_dir/"
    echo "✅ Server configuration backed up"
  fi

  # クライアント設定のコピー
  if [ -d "$HOMEDIR/wireguard" ]; then
    cp -r "$HOMEDIR/wireguard" "$backup_temp_dir/"
    echo "✅ Client configurations backed up"
  fi

  # サービス状態の保存
  local service_status=$(systemctl is-active wg-quick@wg0 2>/dev/null || echo "inactive")
  echo "$service_status" > "$backup_temp_dir/service_status.txt"
  echo "✅ Service status saved"

  # アーカイブの作成
  cd "$temp_dir" && tar -czf "$backup_file" "wireguard_backup" 2>/dev/null

  if [ $? -eq 0 ]; then
    echo "✅ Full backup created successfully!"
    echo "📁 Backup file: $backup_file"
    echo "📊 Backup size: $(stat -c%s "$backup_file" 2>/dev/null | xargs -I {} echo "scale=2; {}/1024/1024" | bc 2>/dev/null || echo "unknown") MB"
  else
    echo "❌ Failed to create backup archive"
    rm -f "$backup_file"
    exit 1
  fi

  # 一時ディレクトリの削除
  rm -rf "$temp_dir"

  # 適切な権限設定
  chown "$USERNAME:" "$backup_file" 2>/dev/null || true
  chmod 600 "$backup_file"

  # 古いバックアップのクリーンアップ（最新10個以外を削除）
  local backup_count=$(ls -1 "$backup_dir"/wireguard_backup_*.tar.gz 2>/dev/null | wc -l)
  if [ "$backup_count" -gt 10 ]; then
    ls -1t "$backup_dir"/wireguard_backup_*.tar.gz | tail -n +11 | xargs rm -f 2>/dev/null || true
    echo "🧹 Old backups cleaned up (keeping latest 10)"
  fi

  echo ""
  echo "🔐 Security Notice:"
  echo "   - Store backup files securely as they contain sensitive key material"
  echo "   - Consider encrypting backups for long-term storage"
}

restore_config() {
  local backup_file=$1

  if [ ! -f "$backup_file" ]; then
    echo "❌ Error: Backup file '$backup_file' not found."
    exit 1
  fi

  echo "🔄 Restoring WireGuard configuration from: $backup_file"

  # バックアップファイルの検証
  if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
    echo "❌ Error: Invalid backup file format."
    exit 1
  fi

  # バックアップにwireguard_backupディレクトリが含まれているか確認
  if ! tar -tf "$backup_file" | grep -q "^wireguard_backup/"; then
    echo "❌ Error: Invalid backup file structure."
    exit 1
  fi

  # 現在の設定のバックアップ（念のため）
  local emergency_backup="$HOMEDIR/wireguard_emergency_backup_$(date +%Y%m%d_%H%M%S)"
  if [ -d /etc/wireguard ] || [ -d "$HOMEDIR/wireguard" ]; then
    mkdir -p "$emergency_backup"
    cp -r /etc/wireguard "$emergency_backup/" 2>/dev/null || true
    cp -r "$HOMEDIR/wireguard" "$emergency_backup/" 2>/dev/null || true
    echo "🛡️  Emergency backup created: $emergency_backup"
  fi

  # 一時ディレクトリを作成
  local temp_dir=$(mktemp -d)
  cd "$temp_dir"

  # バックアップの展開
  if ! tar -xzf "$backup_file"; then
    echo "❌ Error: Failed to extract backup file."
    rm -rf "$temp_dir"
    exit 1
  fi

  if [ ! -d "wireguard_backup" ]; then
    echo "❌ Error: Backup structure is invalid."
    rm -rf "$temp_dir"
    exit 1
  fi

  echo "📂 Extracting backup contents..."

  # WireGuardサービスの停止
  if systemctl is-active --quiet wg-quick@wg0; then
    echo "🛑 Stopping WireGuard service..."
    systemctl stop wg-quick@wg0
  fi

  # サーバー設定の復元
  if [ -d "wireguard_backup/wireguard" ]; then
    rm -rf /etc/wireguard
    cp -r "wireguard_backup/wireguard" /etc/
    echo "✅ Server configuration restored"
  fi

  # クライアント設定の復元
  if [ -d "wireguard_backup/wireguard" ]; then
    rm -rf "$HOMEDIR/wireguard"
    cp -r "wireguard_backup/wireguard" "$HOMEDIR/"
    chown -R "$USERNAME:" "$HOMEDIR/wireguard" 2>/dev/null || true
    echo "✅ Client configurations restored"
  fi

  # 適切な権限設定
  if [ -d /etc/wireguard ]; then
    chmod 600 /etc/wireguard/wg0.conf 2>/dev/null || true
    chmod 700 /etc/wireguard/scripts/* 2>/dev/null || true
    find /etc/wireguard/keys -type f -exec chmod 600 {} \; 2>/dev/null || true
    echo "✅ File permissions restored"
  fi

  # 一時ディレクトリの削除
  rm -rf "$temp_dir"

  # 設定の検証
  echo "🔍 Validating restored configuration..."
  if validate_config >/dev/null 2>&1; then
    echo "✅ Configuration validation passed"

    # サービスの起動
    echo "🚀 Starting WireGuard service..."
    if systemctl start wg-quick@wg0; then
      echo "✅ WireGuard service started successfully"
    else
      echo "⚠️  Failed to start WireGuard service"
    fi
  else
    echo "❌ Configuration validation failed"
    echo "🔧 Please check the restored configuration manually"
    echo "🛡️ Emergency backup available: $emergency_backup"
    exit 1
  fi

  echo "✅ WireGuard configuration restored successfully!"
  echo ""
  echo "📋 Restoration Summary:"
  echo "   - Backup file: $backup_file"
  echo "   - Emergency backup: $emergency_backup"
  echo "   - Service status: $(systemctl is-active wg-quick@wg0 2>/dev/null || echo "unknown")"

  if [ -n "$emergency_backup" ]; then
    echo ""
    echo "🛡️ If something goes wrong, you can restore from: $emergency_backup"
  fi
}

show_status() {
  echo "=== WireGuard Service Status ==="
  echo ""

  # 設定ファイルの存在確認
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "❌ WireGuard is not initialized."
    echo "   Run '$0 init' to initialize WireGuard server."
    return 1
  fi

  # サービス状態の確認
  if systemctl is-active --quiet wg-quick@wg0; then
    echo "🟢 Service: Running"
  else
    echo "🔴 Service: Stopped"
  fi

  # インターフェース状態の確認
  if ip link show wg0 >/dev/null 2>&1; then
    echo "🟢 Interface: Up"
    local wg_ip=$(ip addr show wg0 | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
    echo "   IP Address: $wg_ip"
  else
    echo "🔴 Interface: Down"
  fi

  echo ""

  # wg show コマンドで詳細情報を取得
  if command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    echo "=== Interface Information ==="
    wg show wg0
    echo ""

    echo "=== Peer Information ==="
    local peer_count=$(wg show wg0 peers | wc -l)
    if [ "$peer_count" -gt 0 ]; then
      echo "Connected peers: $peer_count"

      # 各ピアの詳細情報を表示
      while IFS= read -r peer; do
        if [ -n "$peer" ]; then
          echo ""
          echo "Peer: $peer"
          wg show wg0 peer "$peer" | while IFS= read -r line; do
            echo "  $line"
          done
        fi
      done <<< "$(wg show wg0 peers)"
    else
      echo "No peers connected."
    fi
  else
    echo "WireGuard tools not available or interface not active."
  fi

  echo ""
  echo "=== Recent Logs ==="
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u wg-quick@wg0 -n 5 --no-pager -q 2>/dev/null || echo "No recent logs available."
  else
    echo "journalctl not available."
  fi
}

start_service() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  echo "Starting WireGuard service..."
  if systemctl start wg-quick@wg0; then
    echo "✅ WireGuard service started successfully."
    # インターフェースが起動するまで少し待つ
    sleep 2
    if ip link show wg0 >/dev/null 2>&1; then
      local wg_ip=$(ip addr show wg0 | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
      echo "   Interface wg0 is up with IP: $wg_ip"
    fi
  else
    echo "❌ Failed to start WireGuard service."
    exit 1
  fi
}

stop_service() {
  echo "Stopping WireGuard service..."
  if systemctl stop wg-quick@wg0; then
    echo "✅ WireGuard service stopped successfully."
  else
    echo "❌ Failed to stop WireGuard service."
    exit 1
  fi
}

restart_service() {
  if [ ! -f /etc/wireguard/wg0.conf ]; then
    echo "Error: WireGuard is not initialized. Run 'init' first."
    exit 1
  fi

  echo "Restarting WireGuard service..."
  if systemctl restart wg-quick@wg0; then
    echo "✅ WireGuard service restarted successfully."
    # インターフェースが起動するまで少し待つ
    sleep 2
    if ip link show wg0 >/dev/null 2>&1; then
      local wg_ip=$(ip addr show wg0 | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
      echo "   Interface wg0 is up with IP: $wg_ip"
    fi
  else
    echo "❌ Failed to restart WireGuard service."
    exit 1
  fi
}

# ========= main =========
if [[ $# -lt 1 ]]; then
  usage
fi
CMD=$1
shift

case "$CMD" in
  init) init_wireguard "$1" ;;
  add)  [[ $# -lt 2 ]] || [[ $# -gt 3 ]] && usage; add_client "$1" "$2" "$3" ;;
  del)  [[ $# -ne 1 ]] && usage; delete_client "$1" ;;
  list) [[ $# -ne 0 ]] && usage; list_clients ;;
  connected) [[ $# -ne 0 ]] && usage; list_connected_clients ;;
  enable) [[ $# -ne 1 ]] && usage; enable_client "$1" ;;
  disable) [[ $# -ne 1 ]] && usage; disable_client "$1" ;;
  validate) [[ $# -ne 0 ]] && usage; validate_config ;;
  health) [[ $# -ne 0 ]] && usage; health_check ;;
  stats) [[ $# -gt 1 ]] && usage; show_stats "$1" ;;
  export) [[ $# -ne 1 ]] && usage; export_client "$1" ;;
  import) [[ $# -ne 1 ]] && usage; import_client "$1" ;;
  backup) [[ $# -ne 0 ]] && usage; backup_config ;;
  restore) [[ $# -ne 1 ]] && usage; restore_config "$1" ;;
  status) [[ $# -ne 0 ]] && usage; show_status ;;
  start) [[ $# -ne 0 ]] && usage; start_service ;;
  stop) [[ $# -ne 0 ]] && usage; stop_service ;;
  restart) [[ $# -ne 0 ]] && usage; restart_service ;;
  *) usage ;;
esac
