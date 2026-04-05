#!/bin/bash
#===============================================================================
# 单公网 IP VPS — SOCKS5 一键脚本（网页浏览优先：稳定、低延迟）
# 相对多 IP 版改动：
# 1) 仅 1 个公网 IP：优先自动探测，也可手动输入
# 2) 不向网卡额外 add 地址（避免误绑他机 IP）
# 3) 保留 TCP/队列调优与 3proxy 强认证，单端口监听 0.0.0.0
# 说明：「不容易封」依赖合规使用与云安全组；脚本侧侧重连接稳定与内核参数
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
gen_pass() { echo "P@$(rand_hex 10)"; }
gen_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 20000-56000 -n 1
    else
        echo $((20000 + (RANDOM % 36000)))
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

SOCKS_USER="$(gen_user)"
SOCKS_PASS="$(gen_pass)"
SOCKS_PORT="$(gen_port)"
echo ""
echo "========== 自动生成参数 =========="
echo "账号: 自动随机"
echo "密码: 自动随机"
echo "SOCKS5 端口: ${SOCKS_PORT}"

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

echo "[2/5] 低延迟与浏览稳定性（TCP + 队列）"
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

echo "[4/5] 生成 3proxy 配置（仅 SOCKS5，网页建议客户端用 socks5h）"
cat > /etc/3proxy.cfg << EOF
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
daemon
auth strong
users ${SOCKS_USER}:CL:${SOCKS_PASS}
allow ${SOCKS_USER}
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

echo "[5/5] 防火墙放行端口"
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${SOCKS_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi
iptables -D INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport "$SOCKS_PORT" -j ACCEPT

echo "[自检]"
if ss -tlnp 2>/dev/null | grep -Eq ":${SOCKS_PORT}[[:space:]]"; then
    echo "  SOCKS5 端口 ${SOCKS_PORT}: 已监听"
else
    echo "  警告: SOCKS5 端口 ${SOCKS_PORT} 未监听"
fi

if command -v curl >/dev/null 2>&1; then
    curl -s -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 -o /dev/null -w "  SOCKS5 自检 HTTP 状态: %{http_code}\n" "https://www.gstatic.com/generate_204" || true
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
    ss -tlnp | grep -E ":${SOCKS_PORT}[[:space:]]" || true
    echo
    echo "===== PROCESS ====="
    ps -ef | grep "[3]proxy" || true
    echo
    echo "===== LOCAL SOCKS TEST ====="
    curl -sv -x "socks5h://${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT}" --connect-timeout 8 "https://www.gstatic.com/generate_204" -o /dev/null 2>&1 || true
} > "${DEBUG_FILE}" 2>&1

mkdir -p "$(dirname "$OUTPUT_FILE")"
echo "${PUBLIC_IP}|${SOCKS_PORT}|${SOCKS_USER}|${SOCKS_PASS}|${EXPIRE_DATE}" > "$OUTPUT_FILE"

echo ""
echo "========== 代理信息（已保存: $OUTPUT_FILE）=========="
cat "$OUTPUT_FILE"
echo "======================================================="
echo "格式: IP|端口|账号|密码|过期时间"
echo "浏览器/客户端请使用 SOCKS5，并开启「远程 DNS」(socks5h)，网页解析更稳"
echo "若外网不通：云安全组放行 TCP ${SOCKS_PORT}；本机防火墙已尝试放行"
echo "详细诊断: ${DEBUG_FILE}"
