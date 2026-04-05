#!/bin/bash
#===============================================================================
# 单公网 IP VPS — HTTP + SOCKS5 一键脚本（网页浏览：吞吐与长连接稳定）
# 1) 同一组账号密码；HTTP 与 SOCKS5 各随机高端口
# 2) 内核与 3proxy 针对多标签/下载/HTTPS 优化（非游戏场景）
# 3) 输出可直接粘贴的 http:// 与 socks5h:// 地址（密码避免 URL 特殊字符）
#===============================================================================

set -euo pipefail

OUTPUT_FILE="/root/proxy_list.txt"
DEBUG_FILE="/root/proxy_debug.txt"
IP_FILE="/root/public_ip.txt"
DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")
EXPIRE_DATE=$(date -d "+45 days" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+45d "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "N/A")

rand_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        dd if=/dev/urandom bs=1 count=$(( "$1" * 2 )) 2>/dev/null | xxd -p -c 256
    fi
}

gen_user() { echo "u$(rand_hex 4)"; }
# 避免 @ : / ? # 等破坏 http://user:pass@host 粘贴
gen_pass() { echo "Pw$(rand_hex 14)"; }
gen_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-56000 -n 1
    else
        echo $((20000 + (RANDOM % 36000)))
    fi
}

pick_two_ports() {
    HTTP_PORT="$(gen_port)"
    SOCKS_PORT="$(gen_port)"
    local i=0
    while [ "$HTTP_PORT" -eq "$SOCKS_PORT" ] && [ "$i" -lt 50 ]; do
        SOCKS_PORT="$(gen_port)"
        i=$((i + 1))
    done
    if [ "$HTTP_PORT" -eq "$SOCKS_PORT" ]; then
        SOCKS_PORT=$((HTTP_PORT + 1))
    fi
}

detect_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com"; do
        ip=$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\r\n ' || true)
        [[ -n "$ip" ]] && break
    done
    echo "$ip"
}

PROXY_USER="$(gen_user)"
PROXY_PASS="$(gen_pass)"
pick_two_ports
echo ""
echo "========== 自动生成参数 =========="
echo "账号: ${PROXY_USER}"
echo "密码: ${PROXY_PASS}"
echo "HTTP  代理端口: ${HTTP_PORT}"
echo "SOCKS5 端口:     ${SOCKS_PORT}"

touch "$IP_FILE"
chmod 600 "$IP_FILE"
saved=""
[ -s "$IP_FILE" ] && saved=$(head -n1 "$IP_FILE" | tr -d '\r\n')

auto_ip="$(detect_public_ip)"
echo ""
echo "公网 IP：直接回车 = 优先使用已保存；输入新 IP 覆盖；输入 auto 尝试自动探测"
[ -n "$saved" ] && echo "当前已保存: ${saved}"
[ -n "$auto_ip" ] && echo "自动探测到: ${auto_ip}"
read -r -p "公网 IP [回车/auto/手动]: " ip_in

if [ -z "${ip_in}" ]; then
    if [ -n "$saved" ]; then
        PUBLIC_IP="$saved"
        echo "使用已保存 IP: $PUBLIC_IP"
    elif [ -n "$auto_ip" ]; then
        PUBLIC_IP="$auto_ip"
        echo "$PUBLIC_IP" > "$IP_FILE"
        chmod 600 "$IP_FILE"
        echo "使用自动探测 IP: $PUBLIC_IP"
    else
        echo "错误: 无已保存 IP 且自动探测失败，请手动输入后重跑。"
        exit 1
    fi
elif [ "${ip_in}" = "auto" ] || [ "${ip_in}" = "AUTO" ]; then
    if [ -z "$auto_ip" ]; then
        echo "错误: 自动探测失败，请检查出站网络或手动输入 IP。"
        exit 1
    fi
    PUBLIC_IP="$auto_ip"
    echo "$PUBLIC_IP" > "$IP_FILE"
    chmod 600 "$IP_FILE"
    echo "使用自动探测 IP: $PUBLIC_IP"
else
    PUBLIC_IP="${ip_in}"
    echo "$PUBLIC_IP" > "$IP_FILE"
    chmod 600 "$IP_FILE"
fi

echo "[1/5] 单 IP 模式：跳过向网卡绑定额外公网地址（使用云厂商已分配的地址即可）"

echo "[2/5] 网页向 TCP/缓冲与队列（吞吐、多连接、长页面）"
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-web-proxy.conf << 'SYSCTL'
# 多标签/长连接：略放宽 keepalive，减少误杀空闲连接
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
# 下载/HTTPS 大吞吐
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.ip_local_port_range = 10240 65535
vm.min_free_kbytes = 65536
SYSCTL
sysctl -p /etc/sysctl.d/99-web-proxy.conf >/dev/null 2>&1 || true

install_3proxy_from_source() {
    echo "  仓库里没有 3proxy，改为从 GitHub 源码编译到 /usr/local/bin/3proxy …"
    if ! command -v gcc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y build-essential git ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y gcc make git ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y gcc make git ca-certificates
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache gcc make musl-dev git
        else
            echo "错误: 无法自动安装编译依赖（gcc/make/git），请手动装好后再运行本脚本。"
            return 1
        fi
    fi
    local tmp
    tmp=$(mktemp -d)
    if ! git clone --depth 1 https://github.com/z3apa3a/3proxy.git "$tmp/3p"; then
        rm -rf "$tmp"
        return 1
    fi
    if ! (cd "$tmp/3p" && make -f Makefile.Linux); then
        echo "错误: 3proxy 编译失败，请把终端完整输出发给维护者或手动编译。"
        rm -rf "$tmp"
        return 1
    fi
    if [ ! -f "$tmp/3p/bin/3proxy" ]; then
        echo "错误: 编译结束但未生成 bin/3proxy。"
        rm -rf "$tmp"
        return 1
    fi
    install -m 755 "$tmp/3p/bin/3proxy" /usr/local/bin/3proxy
    rm -rf "$tmp"
}

echo "[3/5] 安装 3proxy"
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y epel-release >/dev/null 2>&1 || true
        dnf install -y 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1 || true
        yum install -y 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || true
        apt-get install -y 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache 3proxy >/dev/null 2>&1 || true
    fi
fi
if ! command -v 3proxy >/dev/null 2>&1; then
    install_3proxy_from_source || {
        echo "错误: 未能安装或编译 3proxy。若系统极简，请执行: apt install build-essential git 或 yum install gcc make git 后重试。"
        exit 1
    }
fi

THREE_PROXY_BIN=""
for p in /usr/local/bin/3proxy /usr/bin/3proxy /usr/sbin/3proxy; do
    if [ -x "$p" ]; then
        THREE_PROXY_BIN="$p"
        break
    fi
done
if [ -z "$THREE_PROXY_BIN" ]; then
    echo "错误: 未找到可执行的 3proxy。"
    exit 1
fi
echo "  使用 3proxy: $THREE_PROXY_BIN"

echo "[4/5] 生成 3proxy 配置（HTTP CONNECT + SOCKS5，同一账号）"
cat > /etc/3proxy.cfg << EOF
nserver 1.1.1.1
nserver 1.0.0.1
nserver 8.8.8.8
nscache 262144
# 浏览向：略拉长空闲与整体会话时间，减少大页面/后台标签断连
timeouts 1 10 60 180 600 7200 30 180
daemon
auth strong
users ${PROXY_USER}:CL:${PROXY_PASS}
allow ${PROXY_USER}
proxy -p${HTTP_PORT} -i0.0.0.0 -e0.0.0.0 -u2
socks -p${SOCKS_PORT} -i0.0.0.0 -e0.0.0.0 -u2
EOF

chmod 600 /etc/3proxy.cfg

cat > /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
LimitNOFILE=1048576
ExecStart=${THREE_PROXY_BIN} /etc/3proxy.cfg
ExecStop=/usr/bin/pkill 3proxy
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable 3proxy >/dev/null 2>&1 || true
systemctl restart 3proxy

echo "[5/5] 防火墙放行端口（HTTP + SOCKS5）"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${HTTP_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
for _p in "$HTTP_PORT" "$SOCKS_PORT"; do
    iptables -D INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p tcp --dport "$_p" -j ACCEPT
done

echo "[自检]"
if ss -tlnp 2>/dev/null | grep -Eq ":${HTTP_PORT}[[:space:]]"; then
    echo "  HTTP  代理端口 ${HTTP_PORT}: 已监听"
else
    echo "  警告: HTTP  代理端口 ${HTTP_PORT} 未监听"
fi
if ss -tlnp 2>/dev/null | grep -Eq ":${SOCKS_PORT}[[:space:]]"; then
    echo "  SOCKS5 端口 ${SOCKS_PORT}: 已监听"
else
    echo "  警告: SOCKS5 端口 ${SOCKS_PORT} 未监听"
fi

if command -v curl >/dev/null 2>&1; then
    curl -s -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${HTTP_PORT}" --connect-timeout 8 -o /dev/null -w "  HTTP  自检 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
    curl -s -x "socks5h://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 -o /dev/null -w "  SOCKS5 自检 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
fi

echo "[诊断] 输出调试信息到 ${DEBUG_FILE}"
{
    echo "===== DATE ====="
    date
    echo
    echo "===== IP ADDR ====="
    ip -4 addr show "$DEFAULT_IFACE" || true
    echo
    echo "===== PUBLIC IP (script) ====="
    echo "$PUBLIC_IP"
    echo
    echo "===== 3PROXY CONFIG ====="
    sed 's/users .*/users ***:CL:***/' /etc/3proxy.cfg || true
    echo
    echo "===== SYSTEMD STATUS ====="
    systemctl status 3proxy --no-pager -l || true
    echo
    echo "===== LISTEN PORT ====="
    ss -tlnp | grep -E ":(${HTTP_PORT}|${SOCKS_PORT})[[:space:]]" || true
    echo
    echo "===== PROCESS ====="
    ps -ef | grep "[3]proxy" || true
    echo
    echo "===== LOCAL HTTP TEST ====="
    curl -sv -x "http://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${HTTP_PORT}" --connect-timeout 8 "https://www.gstatic.com/generate_204" -o /dev/null 2>&1 || true
    echo
    echo "===== LOCAL SOCKS TEST ====="
    curl -sv -x "socks5h://${PROXY_USER}:${PROXY_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 "https://www.gstatic.com/generate_204" -o /dev/null 2>&1 || true
} > "${DEBUG_FILE}" 2>&1

HTTP_URL="http://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${HTTP_PORT}"
SOCKS_URL="socks5h://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${SOCKS_PORT}"

mkdir -p "$(dirname "$OUTPUT_FILE")"
{
    echo "# 字段: 公网IP|HTTP端口|SOCKS端口|账号|密码|过期"
    echo "${PUBLIC_IP}|${HTTP_PORT}|${SOCKS_PORT}|${PROXY_USER}|${PROXY_PASS}|${EXPIRE_DATE}"
    echo ""
    echo "HTTP=${HTTP_URL}"
    echo "SOCKS5=${SOCKS_URL}"
} > "$OUTPUT_FILE"

echo ""
echo "========== 代理信息（已保存: $OUTPUT_FILE）=========="
cat "$OUTPUT_FILE"
echo "======================================================="
echo "浏览器「HTTP 代理」填: ${PUBLIC_IP}  端口 ${HTTP_PORT}  账号密码同上（HTTPS 走 CONNECT，无需额外插件）"
echo "扩展/系统代理若支持 SOCKS：用 socks5h 或勾选远程 DNS，地址同上 SOCKS 行"
echo "云安全组请放行 TCP: ${HTTP_PORT} 与 ${SOCKS_PORT}"
echo "详细诊断: ${DEBUG_FILE}"
