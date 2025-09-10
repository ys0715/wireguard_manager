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

            echo "  🟢 Status: Connected"
            ((connected_count++))
          else
            echo "  🔴 Status: Disconnected"
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
  status) [[ $# -ne 0 ]] && usage; show_status ;;
  start) [[ $# -ne 0 ]] && usage; start_service ;;
  stop) [[ $# -ne 0 ]] && usage; stop_service ;;
  restart) [[ $# -ne 0 ]] && usage; restart_service ;;
  *) usage ;;
esac
