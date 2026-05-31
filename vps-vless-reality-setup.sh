#!/bin/bash
#===============================================================================
# VPS 网页浏览：VLESS + Reality + Vision（对齐 SOCKS5 成功模式，不影响 40001）
# 关键修复：
#   1. 端口改用 40002（与 SOCKS 40001 同段，安全组规则照抄即可）
#   2. 监听 0.0.0.0（与 SOCKS 一致，不再绑单 IP）
#   3. 自动绑定三公网 IP 到网卡（原 Reality 脚本缺失此步）
#   4. 单 UUID 单 inbound，三条链接仅 IP 不同
# 使用: bash vps-vless-reality-setup.sh
#===============================================================================

set -e

SOCKS_PORT=40001
XRAY_PORT=40002
XRAY_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
OUTPUT_FILE="/root/vless_reality_links.txt"
IP_FILE="/root/public_ips.txt"
CONFIG_FILE="${XRAY_DIR}/config.json"
SERVICE_NAME="xray"
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")

REALITY_DEST="www.microsoft.com:443"
REALITY_SNI="www.microsoft.com"
NODE_NAMES=("VPS-Reality-1" "VPS-Reality-2" "VPS-Reality-3")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

open_port() {
    local port=$1
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null 2>/dev/null; then
        firewall-cmd --permanent --add-port=${port}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
}

# ---------- 读取公网 IP ----------
if [ ! -s "$IP_FILE" ]; then
    error "未找到 $IP_FILE，请先运行 SOCKS5 脚本或写入 3 行公网 IP"
fi
mapfile -t PUBLIC_IPS < "$IP_FILE"
[ ${#PUBLIC_IPS[@]} -lt 3 ] && error "$IP_FILE 至少需要 3 行 IP"
PUBLIC_IPS=("${PUBLIC_IPS[0]}" "${PUBLIC_IPS[1]}" "${PUBLIC_IPS[2]}")
info "公网 IP: ${PUBLIC_IPS[*]}"

# ---------- 绑定公网 IP（SOCKS 脚本有，原 Reality 脚本缺失） ----------
info "绑定公网 IP 到网卡 $DEFAULT_IFACE"
for pub in "${PUBLIC_IPS[@]}"; do
    if ip addr show "$DEFAULT_IFACE" 2>/dev/null | grep -qF "$pub"; then
        info "  $pub 已绑定"
    else
        ip addr add "$pub/32" dev "$DEFAULT_IFACE" 2>/dev/null && info "  已绑定 $pub" || warn "  绑定 $pub 失败"
    fi
done

# ---------- SOCKS5 状态（不修改） ----------
if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT} "; then
    info "SOCKS5 端口 ${SOCKS_PORT} 正常，本脚本不会改动"
else
    warn "SOCKS5 端口 ${SOCKS_PORT} 未监听（Reality 仍会继续安装）"
fi

install_xray() {
    if [ -x "$XRAY_BIN" ]; then
        info "Xray 已安装: $($XRAY_BIN version 2>/dev/null | head -1 || echo unknown)"
        return 0
    fi
    info "正在安装 Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [ -x "$XRAY_BIN" ] || error "Xray 安装失败"
}

gen_uuid() { "$XRAY_BIN" uuid; }
gen_short_id() { openssl rand -hex 8 2>/dev/null || head -c 8 /dev/urandom | xxd -p; }

parse_x25519_keys() {
    local output="$1"
    PRIVATE_KEY=$(echo "$output" | grep -E '^PrivateKey:|^Private key:' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo "$output" | grep -E '^Password|^Public key:' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
}

install_xray

info "生成 Reality 密钥..."
KEYS=$("$XRAY_BIN" x25519 2>&1) || error "xray x25519 失败: $KEYS"
parse_x25519_keys "$KEYS"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || { echo "$KEYS"; error "密钥解析失败"; }
info "PublicKey: ${PUBLIC_KEY:0:12}..."

UUID=$(gen_uuid)
SHORT_ID=$(gen_short_id)
info "UUID: $UUID  ShortId: $SHORT_ID"

# ---------- 测试 Reality 回落站点可达 ----------
info "测试回落站点 $REALITY_DEST ..."
if ! timeout 5 curl -sI "https://${REALITY_SNI}" | head -1 | grep -qE '200|301|302'; then
    warn "VPS 访问 $REALITY_SNI 异常，Reality 可能握手失败"
else
    info "回落站点 $REALITY_SNI 可达"
fi

# ---------- 构建配置：单 inbound，0.0.0.0:40002（对齐 SOCKS 模式） ----------
mkdir -p "$XRAY_DIR" /var/log/xray
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"

cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "web@local"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": []
  }
}
EOF

"$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1 || error "配置校验失败，查看 $CONFIG_FILE"

info "放行 TCP ${XRAY_PORT}（与 SOCKS ${SOCKS_PORT} 同样方式）"
open_port "$XRAY_PORT"

systemctl enable "$SERVICE_NAME" 2>/dev/null || true
systemctl restart "$SERVICE_NAME"
sleep 2
systemctl is-active --quiet "$SERVICE_NAME" || error "Xray 启动失败: journalctl -u xray -n 30 --no-pager"

ss -tlnp 2>/dev/null | grep -q "0.0.0.0:${XRAY_PORT} " || \
    ss -tlnp 2>/dev/null | grep -q ":${XRAY_PORT} " || \
    error "端口 ${XRAY_PORT} 未监听"

# ---------- 生成链接（3 IP 共用同一端口/UUID） ----------
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
echo "# VLESS Reality | 端口 ${XRAY_PORT} | 监听 0.0.0.0 | $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
echo "# SOCKS5 仍在 ${SOCKS_PORT}，互不影响" >> "$OUTPUT_FILE"
echo "# 阿里云安全组：照抄 ${SOCKS_PORT} 的规则，再加 TCP ${XRAY_PORT}" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

for i in 0 1 2; do
    IP="${PUBLIC_IPS[$i]}"
    NAME="${NODE_NAMES[$i]}"
    ENC_NAME=$(urlencode "$NAME")
    LINK="vless://${UUID}@${IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${ENC_NAME}"
    echo "$LINK" >> "$OUTPUT_FILE"
done

# Clash Meta 完整配置
CLASH_FILE="/root/clash-meta.yaml"
cat > "$CLASH_FILE" << 'HEAD'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
dns:
  enable: true
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 8.8.8.8
proxies:
HEAD

for i in 0 1 2; do
    cat >> "$CLASH_FILE" << EOF
  - name: "${NODE_NAMES[$i]}"
    type: vless
    server: ${PUBLIC_IPS[$i]}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: "${SHORT_ID}"
EOF
done

cat >> "$CLASH_FILE" << EOF

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - ${NODE_NAMES[0]}
      - ${NODE_NAMES[1]}
      - ${NODE_NAMES[2]}
      - DIRECT
rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF

echo ""
echo "============================================================"
echo "  安装完成 — 端口 ${XRAY_PORT}（与 SOCKS ${SOCKS_PORT} 同策略）"
echo "============================================================"
echo ""
cat "$OUTPUT_FILE" | grep -v '^#'
echo ""
echo "Public Key : ${PUBLIC_KEY}"
echo "UUID       : ${UUID}"
echo "Short ID   : ${SHORT_ID}"
echo "SNI        : ${REALITY_SNI}"
echo ""
echo "--- 必做：阿里云安全组 ---"
echo "  你已放行 TCP ${SOCKS_PORT}，请同样添加 TCP ${XRAY_PORT}/40002 入站 0.0.0.0/0"
echo ""
echo "--- Windows 测试 ---"
echo "  Test-NetConnection ${PUBLIC_IPS[0]} -Port ${XRAY_PORT}"
echo "  必须 TcpTestSucceeded : True 才能连"
echo ""
echo "--- v2rayN ---"
echo "  复制上面 vless:// 链接 → 从剪贴板导入"
echo "  传输=raw  安全=reality  Flow=xtls-rprx-vision  内核=Xray"
echo ""
echo "--- 文件 ---"
echo "  链接: $OUTPUT_FILE"
echo "  Clash: $CLASH_FILE"
echo "  配置: $CONFIG_FILE"
echo "============================================================"
