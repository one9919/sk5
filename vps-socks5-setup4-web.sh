#!/bin/bash
#===============================================================================
# 单 VPS 三公网 IP 代理一键脚本（仅 SOCKS5）
# 目标：
# 1) 只手动输入 3 个公网 IP，其他自动生成
# 2) 一台机器仅一组账号密码 + 同一组端口
# 3) 兼顾网页浏览与游戏加速（稳定、低延迟、不掉线）
#===============================================================================

set -euo pipefail

OUTPUT_FILE="/root/proxy_list.txt"
IP_FILE="/root/public_ips.txt"
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")
EXPIRE_DATE=$(date -d "+45 days" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+45d "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")
SOCKS_PROTO="SOCKS5"

rand_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        dd if=/dev/urandom bs=1 count=$(( "$1" * 2 )) 2>/dev/null | xxd -p -c 256
    fi
}

gen_user() { echo "u$(rand_hex 4)"; }
gen_pass() { echo "P@$(rand_hex 10)"; }
gen_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-56000 -n 1
    else
        echo $((20000 + (RANDOM % 36000)))
    fi
}

SOCKS_USER="$(gen_user)"
SOCKS_PASS="$(gen_pass)"
SOCKS_PORT="$(gen_port)"
echo ""
echo "========== 自动生成参数 =========="
echo "账号: 自动随机"
echo "密码: 自动随机"
echo "SOCKS5端口: ${SOCKS_PORT}"

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

echo "[1/6] 绑定公网 IP 到网卡: $DEFAULT_IFACE"
for pub in "${PUBLIC_IPS[@]}"; do
    if ip addr show "$DEFAULT_IFACE" 2>/dev/null | grep -qF "$pub"; then
        echo "  $pub 已存在"
    else
        ip addr add "$pub/32" dev "$DEFAULT_IFACE" 2>/dev/null && echo "  已绑定 $pub" || echo "  绑定 $pub 失败(可能已存在)"
    fi
done

echo "[2/6] 低延迟稳定性优化（TCP + 队列）"
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-game-proxy.conf << 'SYSCTL'
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 20
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
vm.min_free_kbytes = 65536
SYSCTL
sysctl -p /etc/sysctl.d/99-game-proxy.conf >/dev/null 2>&1 || true

echo "[3/6] 安装 3proxy"
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y 3proxy >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    echo "错误: 未能安装 3proxy，请手工安装后重试。"
    exit 1
fi

echo "[4/6] 生成 3proxy 配置（仅 SOCKS5）"
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
    echo "socks -p${SOCKS_PORT} -i${ip} -e${ip} -u2" >> /etc/3proxy.cfg
done

chmod 600 /etc/3proxy.cfg

cat > /etc/systemd/system/3proxy.service << 'EOF'
[Unit]
Description=3proxy Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/3proxy /etc/3proxy.cfg
ExecStop=/usr/bin/pkill 3proxy
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

if [ ! -x /usr/bin/3proxy ] && [ -x /usr/sbin/3proxy ]; then
    sed -i 's#/usr/bin/3proxy#/usr/sbin/3proxy#g' /etc/systemd/system/3proxy.service
fi

systemctl daemon-reload
systemctl enable 3proxy >/dev/null 2>&1 || true
systemctl restart 3proxy

echo "[5/6] 防火墙放行端口"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
iptables -D INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT

echo "[6/6] 连通性自检"
if ss -tlnp 2>/dev/null | grep -Eq ":${SOCKS_PORT}[[:space:]]"; then
    echo "  SOCKS5 端口 ${SOCKS_PORT}: 已监听"
else
    echo "  警告: SOCKS5 端口 ${SOCKS_PORT} 未监听"
fi

if command -v curl >/dev/null 2>&1; then
    curl -s -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 -o /dev/null -w "  SOCKS5 自检 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
: > "$OUTPUT_FILE"
for ip in "${PUBLIC_IPS[@]}"; do
    echo "${ip}|${SOCKS_PORT}|${SOCKS_USER}|${SOCKS_PASS}|${EXPIRE_DATE}" >> "$OUTPUT_FILE"
done

echo ""
echo "========== 代理列表（已保存: $OUTPUT_FILE）=========="
cat "$OUTPUT_FILE"
echo "======================================================="
echo "格式: IP|端口|账号|密码|过期时间"
echo "同一台机器仅一组账号密码，3 个 IP 共用同一组"
echo "网页和游戏都使用 SOCKS5（客户端建议 socks5h，确保 DNS 也走代理）"
echo "若外网仍不通，请在云厂商安全组放行 TCP ${SOCKS_PORT}"
