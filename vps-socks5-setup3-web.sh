#!/bin/bash
#===============================================================================
# 单 VPS 三公网 IP + SOCKS5/HTTP 一键脚本 (CentOS 7+)
# 特性:
# 1) 同时提供 SOCKS5 与 HTTP 代理，兼容游戏和网页浏览
# 2) 默认生成高强度随机账号密码 + 随机高位端口
# 3) 支持按客户端 IP/CIDR 白名单放行，降低被扫风险
# 使用:
# chmod +x vps-socks5-setup3-web.sh && bash vps-socks5-setup3-web.sh
#===============================================================================

set -euo pipefail

OUTPUT_FILE="/root/proxy_list.txt"
IP_FILE="/root/public_ips.txt"
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")
EXPIRE_DATE=$(date -d "+45 days" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+45d "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")

rand_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        # fallback: /dev/urandom
        dd if=/dev/urandom bs=1 count=$(( "$1" * 2 )) 2>/dev/null | xxd -p -c 256
    fi
}

gen_user() {
    echo "u$(rand_hex 4)"
}

gen_pass() {
    echo "P@$(rand_hex 10)"
}

gen_port() {
    # 20000-59999 高位随机端口，避开常见端口
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-59999 -n 1
    else
        echo $((20000 + (RANDOM % 40000)))
    fi
}

SOCKS_USER_DEFAULT="$(gen_user)"
SOCKS_PASS_DEFAULT="$(gen_pass)"
SOCKS_PORT_DEFAULT="$(gen_port)"
HTTP_PORT_DEFAULT=$((SOCKS_PORT_DEFAULT + 1))
[ "$HTTP_PORT_DEFAULT" -gt 65535 ] && HTTP_PORT_DEFAULT=18080

echo ""
echo "========== 安全参数配置 =========="
echo "直接回车将使用随机强密码/高位端口（推荐）"
read -r -p "代理账号 [默认: ${SOCKS_USER_DEFAULT}]: " SOCKS_USER
read -r -p "代理密码 [默认随机强密码]: " SOCKS_PASS
read -r -p "SOCKS5 端口 [默认: ${SOCKS_PORT_DEFAULT}]: " SOCKS_PORT
read -r -p "HTTP 端口 [默认: ${HTTP_PORT_DEFAULT}]: " HTTP_PORT
read -r -p "允许连接的客户端 IP/CIDR [默认: 0.0.0.0/0]: " ALLOW_CIDR

SOCKS_USER="${SOCKS_USER:-$SOCKS_USER_DEFAULT}"
SOCKS_PASS="${SOCKS_PASS:-$SOCKS_PASS_DEFAULT}"
SOCKS_PORT="${SOCKS_PORT:-$SOCKS_PORT_DEFAULT}"
HTTP_PORT="${HTTP_PORT:-$HTTP_PORT_DEFAULT}"
ALLOW_CIDR="${ALLOW_CIDR:-0.0.0.0/0}"

if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS_PORT" -lt 1025 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
    echo "错误: SOCKS5 端口必须是 1025-65535 的数字。"
    exit 1
fi
if ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$HTTP_PORT" -lt 1025 ] || [ "$HTTP_PORT" -gt 65535 ]; then
    echo "错误: HTTP 端口必须是 1025-65535 的数字。"
    exit 1
fi
if [ "$SOCKS_PORT" -eq "$HTTP_PORT" ]; then
    echo "错误: SOCKS5 与 HTTP 端口不能相同。"
    exit 1
fi

touch "$IP_FILE"
chmod 600 "$IP_FILE"

saved=()
[ -s "$IP_FILE" ] && mapfile -t saved < "$IP_FILE"

echo ""
echo "请输入 3 个公网 IP（每行一个）:"
[ ${#saved[@]} -ge 3 ] && echo "当前已保存: ${saved[0]}, ${saved[1]}, ${saved[2]}（可回车复用）"
read -r -p "第 1 个: " ip1
read -r -p "第 2 个: " ip2
read -r -p "第 3 个: " ip3

if [ -z "${ip1}" ] || [ -z "${ip2}" ] || [ -z "${ip3}" ]; then
    if [ -s "$IP_FILE" ] && [ ${#saved[@]} -ge 3 ]; then
        ip1="${saved[0]}"
        ip2="${saved[1]}"
        ip3="${saved[2]}"
        echo "使用已保存 IP: $ip1, $ip2, $ip3"
    else
        echo "错误: 必须输入 3 个公网 IP，或保证 $IP_FILE 内已有 3 行。"
        exit 1
    fi
else
    printf '%s\n%s\n%s\n' "$ip1" "$ip2" "$ip3" > "$IP_FILE"
    chmod 600 "$IP_FILE"
fi

PUBLIC_IPS=( "$ip1" "$ip2" "$ip3" )

echo "[1/5] 绑定公网 IP 到网卡: $DEFAULT_IFACE"
for pub in "${PUBLIC_IPS[@]}"; do
    if ip addr show "$DEFAULT_IFACE" 2>/dev/null | rg -qF "$pub"; then
        echo "  $pub 已存在"
    else
        ip addr add "$pub/32" dev "$DEFAULT_IFACE" 2>/dev/null && echo "  已绑定 $pub" || echo "  绑定 $pub 失败(可能已存在)"
    fi
done

echo "[2/5] 系统参数优化"
cat > /etc/sysctl.d/99-game-web-proxy.conf << 'SYSCTL'
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
vm.min_free_kbytes = 65536
SYSCTL
sysctl -p /etc/sysctl.d/99-game-web-proxy.conf >/dev/null 2>&1 || true

echo "[3/5] 安装并配置 3proxy"
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
        yum install -y 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    echo "错误: 未能安装 3proxy，请手工安装后重试。"
    exit 1
fi

cat > /etc/3proxy.cfg << EOF
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
daemon
auth strong
users ${SOCKS_USER}:CL:${SOCKS_PASS}
allow ${SOCKS_USER}
EOF

for ip in "${PUBLIC_IPS[@]}"; do
    # SOCKS5: 兼容游戏/应用，建议客户端使用 socks5h 让 DNS 也走代理
    echo "socks -p${SOCKS_PORT} -i${ip} -e${ip} -u2" >> /etc/3proxy.cfg
    # HTTP/HTTPS 代理: 浏览器兼容性更好
    echo "proxy -n -p${HTTP_PORT} -i${ip} -e${ip}" >> /etc/3proxy.cfg
done

chmod 600 /etc/3proxy.cfg
pkill 3proxy 2>/dev/null || true
sleep 1
3proxy /etc/3proxy.cfg

echo "[4/5] 防火墙放行（含白名单）"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

# 先删旧规则避免重复
iptables -D INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT 2>/dev/null || true

if [ "$ALLOW_CIDR" = "0.0.0.0/0" ]; then
    iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT
    iptables -I INPUT -p tcp --dport "$HTTP_PORT" -j ACCEPT
else
    iptables -I INPUT -p tcp -s "$ALLOW_CIDR" --dport "$SOCKS_PORT" -j ACCEPT
    iptables -I INPUT -p tcp -s "$ALLOW_CIDR" --dport "$HTTP_PORT" -j ACCEPT
fi

echo "[5/5] 连通性自检"
if ss -tlnp 2>/dev/null | rg -q ":${SOCKS_PORT}\b"; then
    echo "  SOCKS5 端口 ${SOCKS_PORT}: 已监听"
else
    echo "  警告: SOCKS5 端口 ${SOCKS_PORT} 未监听"
fi
if ss -tlnp 2>/dev/null | rg -q ":${HTTP_PORT}\b"; then
    echo "  HTTP 端口 ${HTTP_PORT}: 已监听"
else
    echo "  警告: HTTP 端口 ${HTTP_PORT} 未监听"
fi

if command -v curl >/dev/null 2>&1; then
    curl -s -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 -o /dev/null -w "  SOCKS5 测试 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
    curl -s -x "http://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${HTTP_PORT}" --connect-timeout 8 -o /dev/null -w "  HTTP 代理测试 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
: > "$OUTPUT_FILE"
for ip in "${PUBLIC_IPS[@]}"; do
    echo "${ip}|SOCKS5|${SOCKS_PORT}|${SOCKS_USER}|${SOCKS_PASS}|${EXPIRE_DATE}" >> "$OUTPUT_FILE"
    echo "${ip}|HTTP|${HTTP_PORT}|${SOCKS_USER}|${SOCKS_PASS}|${EXPIRE_DATE}" >> "$OUTPUT_FILE"
done

echo ""
echo "========== 代理信息 =========="
cat "$OUTPUT_FILE"
echo "=============================="
echo "格式: IP|协议|端口|账号|密码|过期时间"
echo ""
echo "浏览器建议:"
echo "1) 首选 HTTP 代理（IP + HTTP端口）"
echo "2) 若用 SOCKS，请用 socks5h，确保 DNS 也经代理"
echo ""
echo "安全建议:"
echo "- ALLOW_CIDR 不要用 0.0.0.0/0，尽量填你本机/出口的固定公网 IP"
echo "- 定期更换账号密码与端口"
echo "- 云厂商安全组同样要放行对应端口，并可加来源 IP 白名单"
