#!/bin/bash
#===============================================================================
# VPS 网页浏览专用：VLESS + Reality + Vision（不影响现有 SOCKS5 40001）
# 依赖：已有 /root/public_ips.txt（3 行公网 IP，与原 socks5 脚本共用）
# 使用：bash vps-vless-reality-setup.sh
# 输出：/root/vless_reality_links.txt（机场/Clash 可直接导入的链接）
#===============================================================================

set -e

SOCKS_PORT=40001
XRAY_PORT=443
XRAY_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
OUTPUT_FILE="/root/vless_reality_links.txt"
IP_FILE="/root/public_ips.txt"
CONFIG_FILE="${XRAY_DIR}/config.json"
SERVICE_NAME="xray"

# 三个 Reality 回落站点（均为真实 TLS1.3 站点，降低特征）
REALITY_DESTS=(
    "www.microsoft.com:443"
    "www.cloudflare.com:443"
    "www.samsung.com:443"
)
REALITY_SNIS=(
    "www.microsoft.com"
    "www.cloudflare.com"
    "www.samsung.com"
)
NODE_NAMES=("VPS-Reality-1" "VPS-Reality-2" "VPS-Reality-3")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- 读取公网 IP ----------
if [ ! -s "$IP_FILE" ]; then
    error "未找到 $IP_FILE，请先运行原 SOCKS5 脚本或手动写入 3 行公网 IP"
fi
mapfile -t PUBLIC_IPS < "$IP_FILE"
[ ${#PUBLIC_IPS[@]} -lt 3 ] && error "$IP_FILE 至少需要 3 行 IP，当前 ${#PUBLIC_IPS[@]} 行"
PUBLIC_IPS=("${PUBLIC_IPS[0]}" "${PUBLIC_IPS[1]}" "${PUBLIC_IPS[2]}")
info "公网 IP: ${PUBLIC_IPS[*]}"

# ---------- 确认 SOCKS5 仍在运行（不改动） ----------
if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
    info "检测到 SOCKS5 端口 ${SOCKS_PORT} 正常监听，本脚本不会修改它"
else
    warn "未检测到 SOCKS5 端口 ${SOCKS_PORT}，将继续安装 Reality（不影响 SOCKS 配置）"
fi

# ---------- 安装 Xray ----------
install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1 || echo unknown)"
        return 0
    fi
    info "正在安装 Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [ -x "$XRAY_BIN" ] || error "Xray 安装失败"
}

# ---------- 生成密钥 ----------
gen_uuid() {
    if [ -x "$XRAY_BIN" ]; then
        "$XRAY_BIN" uuid
    elif command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

gen_short_id() {
    openssl rand -hex 4 2>/dev/null || head -c 4 /dev/urandom | xxd -p
}

install_xray

# Xray v25+ 输出格式: PrivateKey / Password(即公钥) / Hash32
# 旧版格式: Private key / Public key
parse_x25519_keys() {
    local output="$1"
    PRIVATE_KEY=$(echo "$output" | awk -F': *' '/^PrivateKey:/ {print $2; exit} /^Private key:/ {print $2; exit}')
    PUBLIC_KEY=$(echo "$output" | awk -F': *' '/^Password:/ {print $2; exit} /^Public key:/ {print $2; exit}')
    PRIVATE_KEY=$(echo "$PRIVATE_KEY" | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$PUBLIC_KEY" | tr -d '[:space:]')
}

info "生成 Reality 密钥对..."
KEYS=$("$XRAY_BIN" x25519 2>&1) || error "xray x25519 执行失败: $KEYS"
parse_x25519_keys "$KEYS"
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "$KEYS"
    error "密钥解析失败（Xray 输出格式可能已变更，请把上面内容发给我）"
fi
info "PrivateKey: ${PRIVATE_KEY:0:8}...  PublicKey: ${PUBLIC_KEY:0:8}..."

UUIDS=()
SHORT_IDS=()
for i in 0 1 2; do
    UUIDS+=("$(gen_uuid)")
    SHORT_IDS+=("$(gen_short_id)")
done

# ---------- 构建 Xray 配置（3 个 inbound，各绑定一个 IP:443） ----------
mkdir -p "$XRAY_DIR"

INBOUNDS=""
for i in 0 1 2; do
    IP="${PUBLIC_IPS[$i]}"
    SID="${SHORT_IDS[$i]}"
    UUID="${UUIDS[$i]}"
    DEST="${REALITY_DESTS[$i]}"
    SNI="${REALITY_SNIS[$i]}"
    INBOUNDS+=$(cat <<EOF

    {
      "tag": "vless-reality-${i}",
      "listen": "${IP}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "user${i}@local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["", "${SID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
EOF
)
    [ "$i" -lt 2 ] && INBOUNDS+=","
done

# 备份旧配置
if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    warn "已备份旧配置到 ${CONFIG_FILE}.bak.*"
fi

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [${INBOUNDS}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

mkdir -p /var/log/xray
"$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1 || error "Xray 配置校验失败，请检查 $CONFIG_FILE"

# ---------- 防火墙放行 443（不动 40001） ----------
info "放行 TCP ${XRAY_PORT}（Reality），不影响 ${SOCKS_PORT}"
if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>/dev/null; then
    firewall-cmd --permanent --add-port=${XRAY_PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi
iptables -C INPUT -p tcp --dport $XRAY_PORT -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport $XRAY_PORT -j ACCEPT

# ---------- 启动服务 ----------
systemctl enable "$SERVICE_NAME" 2>/dev/null || true
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SERVICE_NAME" || error "Xray 启动失败，执行: journalctl -u xray -n 30 --no-pager"

for i in 0 1 2; do
    IP="${PUBLIC_IPS[$i]}"
    ss -tlnp 2>/dev/null | grep -q "${IP}:${XRAY_PORT} " || \
        warn "端口 ${IP}:${XRAY_PORT} 未监听，请检查 IP 是否已绑定到网卡"
done

# ---------- 生成分享链接 ----------
urlencode() {
    local s="$1" out="" c hex i
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    echo -n "$out"
}

: > "$OUTPUT_FILE"
echo "# VLESS Reality 节点 — $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
echo "# 协议: VLESS + Reality + Vision | 端口: ${XRAY_PORT} | 指纹: chrome" >> "$OUTPUT_FILE"
echo "# SOCKS5 游戏代理仍在端口 ${SOCKS_PORT}，互不影响" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

for i in 0 1 2; do
    IP="${PUBLIC_IPS[$i]}"
    UUID="${UUIDS[$i]}"
    SID="${SHORT_IDS[$i]}"
    SNI="${REALITY_SNIS[$i]}"
    NAME="${NODE_NAMES[$i]}"
    ENC_NAME=$(urlencode "$NAME")

    LINK="vless://${UUID}@${IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SID}&type=tcp&headerType=none#${ENC_NAME}"
    echo "$LINK" >> "$OUTPUT_FILE"
done

# Clash Meta 片段
CLASH_FILE="/root/vless_reality_clash.yaml"
cat > "$CLASH_FILE" << 'HEADER'
# Clash Meta / Mihomo 配置片段，合并到 proxies: 段即可
proxies:
HEADER

for i in 0 1 2; do
    IP="${PUBLIC_IPS[$i]}"
    UUID="${UUIDS[$i]}"
    SID="${SHORT_IDS[$i]}"
    SNI="${REALITY_SNIS[$i]}"
    NAME="${NODE_NAMES[$i]}"
    cat >> "$CLASH_FILE" << EOF
  - name: "${NAME}"
    type: vless
    server: ${IP}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SID}
    client-fingerprint: chrome
EOF
done

echo ""
echo "============================================================"
echo "  VLESS + Reality 安装完成（网页浏览专用）"
echo "============================================================"
echo ""
echo "--- 机场软件导入链接（复制任一条即可）---"
echo ""
cat "$OUTPUT_FILE" | grep -v '^#'
echo ""
echo "--- 节点详情 ---"
for i in 0 1 2; do
    echo "  [${NODE_NAMES[$i]}] ${PUBLIC_IPS[$i]}:${XRAY_PORT}  SNI=${REALITY_SNIS[$i]}  UUID=${UUIDS[$i]}"
done
echo ""
echo "  Public Key : ${PUBLIC_KEY}"
echo "  Flow       : xtls-rprx-vision"
echo "  Fingerprint: chrome"
echo ""
echo "--- 文件位置 ---"
echo "  链接列表 : $OUTPUT_FILE"
echo "  Clash片段: $CLASH_FILE"
echo "  Xray配置 : $CONFIG_FILE"
echo ""
echo "--- 客户端设置要点 ---"
echo "  v2rayN / Nekoray / Shadowrocket / Clash Meta 均支持"
echo "  导入方式: 复制 vless:// 链接 → 从剪贴板导入"
echo "  或: 订阅转换 https://sub.xeton.dev/ 粘贴链接生成订阅"
echo ""
echo "--- 云控制台 ---"
echo "  请在安全组额外放行 TCP ${XRAY_PORT} 入站（SOCKS ${SOCKS_PORT} 保持不变）"
echo ""
echo "--- 自检 ---"
echo "  systemctl status xray"
echo "  ss -tlnp | grep ':443'"
echo "  scp root@${PUBLIC_IPS[0]}:$OUTPUT_FILE ."
echo "============================================================"
