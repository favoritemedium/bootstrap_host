#!/bin/bash
# ============================================================
# sing-box 1.13.0 — VLESS+Reality (TCP/443) + Hysteria2 (UDP/8443)
# OS version: Debian 12 (bookworm) — fresh host installer 
# Usage: sudo bash singbox-install.sh
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[✓] $*${NC}"; }
warn()  { echo -e "${YELLOW}[!] $*${NC}"; }
fatal() { echo -e "${RED}[✗] $*${NC}"; exit 1; }
step()  { echo -e "${CYAN}[→] $*${NC}"; }

[ "$EUID" -ne 0 ] && fatal "Run as root: sudo bash singbox-install.sh"

echo -e "${CYAN}"
echo "  ================================================"
echo "   sing-box 1.13.0 — VLESS+Reality + Hysteria2   "
echo "   Debian 12 — $(date '+%Y-%m-%d %H:%M:%S')       "
echo "  ================================================"
echo -e "${NC}"

# ============================================================
# CONFIG — edit these if needed
# ============================================================
SB_VER="1.13.0"
SB_BIN="/usr/local/bin/sing-box"
SB_CONF="/etc/sing-box/config.json"
SB_CREDS="/etc/sing-box/credentials.txt"
VLESS_PORT=443
HY2_PORT=8443
VLESS_SNI="www.microsoft.com"
HY2_SNI="bing.com"

# ============================================================
# 1. DEPENDENCIES
# ============================================================
step "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates
info "Dependencies installed"

# ============================================================
# 2. INSTALL SING-BOX BINARY
# ============================================================
step "Installing sing-box ${SB_VER}..."

if [ -f "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | grep -q "$SB_VER"; then
  info "sing-box ${SB_VER} already present — skipping download"
else
  TARBALL="/tmp/sing-box-${SB_VER}.tar.gz"
  EXTRACT="/tmp/sing-box-${SB_VER}-linux-amd64"

  curl -fL \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-amd64.tar.gz" \
    -o "$TARBALL" || fatal "Download failed — check network/GitHub access"

  tar -xz -C /tmp -f "$TARBALL"
  cp "${EXTRACT}/sing-box" "$SB_BIN"
  chmod +x "$SB_BIN"
  rm -rf "$TARBALL" "$EXTRACT"
fi

# Symlink so both PATH and systemd unit at /usr/bin find it
ln -sf "$SB_BIN" /usr/bin/sing-box

INSTALLED_VER=$("$SB_BIN" version | head -1 | awk '{print $3}')
info "sing-box ${INSTALLED_VER} installed at ${SB_BIN}"

# ============================================================
# 3. GENERATE CREDENTIALS
# ============================================================
step "Generating credentials..."

REALITY_KEYS=$("$SB_BIN" generate reality-keypair)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep PrivateKey | awk '{print $2}')
REALITY_PUBLIC_KEY=$(echo  "$REALITY_KEYS" | grep PublicKey  | awk '{print $2}')
UUID=$("$SB_BIN" generate uuid)
SHORT_ID=$(openssl rand -hex 8)
HYSTERIA_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)

# Detect server IP
SERVER_IP=""
for svc in "ifconfig.me" "icanhazip.com" "api.ipify.org"; do
  SERVER_IP=$(curl -s4 --max-time 5 "$svc" 2>/dev/null || true)
  [ -n "$SERVER_IP" ] && break
done
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
[ -z "$SERVER_IP" ] && fatal "Could not detect server IP"

info "Server IP: ${SERVER_IP}"
info "Credentials generated"

# ============================================================
# 4. TLS CERT FOR HYSTERIA2
# ============================================================
step "Generating self-signed certificate for Hysteria2..."

mkdir -p /etc/sing-box/certs
openssl ecparam -genkey -name prime256v1 \
  -out /etc/sing-box/certs/private.key 2>/dev/null
openssl req -new -x509 -days 3650 \
  -key /etc/sing-box/certs/private.key \
  -out /etc/sing-box/certs/cert.pem \
  -subj "/CN=${HY2_SNI}" 2>/dev/null

info "Certificate generated"

# ============================================================
# 5. WRITE CONFIG
# ============================================================
step "Writing configuration..."

mkdir -p /etc/sing-box /var/lib/sing-box

cat > "$SB_CONF" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },

  "dns": {
    "servers": [
      {
        "tag": "remote-dns",
        "type": "udp",
        "server": "8.8.8.8"
      },
      {
        "tag": "local-dns",
        "type": "udp",
        "server": "223.5.5.5"
      }
    ],
    "final": "remote-dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${VLESS_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${VLESS_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [
        {
          "password": "${HYSTERIA_PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${HY2_SNI}",
        "certificate_path": "/etc/sing-box/certs/cert.pem",
        "key_path": "/etc/sing-box/certs/private.key"
      }
    }
  ],

  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],

  "route": {
    "default_domain_resolver": "remote-dns",
    "rules": [
      {
        "action": "sniff"
      },
      {
        "ip_is_private": true,
        "action": "reject"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

step "Validating config..."
CHECK_OUT=$("$SB_BIN" check -c "$SB_CONF" 2>&1) && CHECK_RC=0 || CHECK_RC=$?
[ -n "$CHECK_OUT" ] && echo "$CHECK_OUT"
[ $CHECK_RC -ne 0 ] && fatal "Config validation failed — aborting"
info "Config valid"

# ============================================================
# 6. SYSTEMD SERVICE
# ============================================================
step "Installing systemd service..."

cat > /lib/systemd/system/sing-box.service << 'SYSTEMD'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box
sleep 3

if systemctl is-active --quiet sing-box; then
  info "sing-box is running"
else
  echo -e "${RED}[✗] sing-box failed to start${NC}"
  journalctl -u sing-box -n 30 --no-pager
  fatal "See logs above"
fi

# ============================================================
# 7. FIREWALL
# ============================================================
step "Configuring firewall..."

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow ${VLESS_PORT}/tcp comment "sing-box VLESS Reality" > /dev/null
  ufw allow ${HY2_PORT}/udp  comment "sing-box Hysteria2"      > /dev/null
  info "UFW rules added"
else
  iptables  -I INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT 2>/dev/null || true
  iptables  -I INPUT -p udp --dport ${HY2_PORT}   -j ACCEPT 2>/dev/null || true
  ip6tables -I INPUT -p tcp --dport ${VLESS_PORT} -j ACCEPT 2>/dev/null || true
  ip6tables -I INPUT -p udp --dport ${HY2_PORT}   -j ACCEPT 2>/dev/null || true
  info "iptables rules added"
fi

# ============================================================
# 8. SAVE CREDENTIALS
# ============================================================
VLESS_URL="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${VLESS_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#VLESS-Reality-${SERVER_IP}"
HY2_URL="hysteria2://${HYSTERIA_PASSWORD}@${SERVER_IP}:${HY2_PORT}?insecure=1&sni=${HY2_SNI}#Hysteria2-${SERVER_IP}"

cat > "$SB_CREDS" << EOF
# ============================================================
# sing-box Credentials
# Generated: $(date)
# ============================================================

[Server]
IP:               ${SERVER_IP}
sing-box version: ${INSTALLED_VER}

[VLESS+Reality — TCP/${VLESS_PORT}]
UUID:             ${UUID}
Short ID:         ${SHORT_ID}
Public Key:       ${REALITY_PUBLIC_KEY}
Private Key:      ${REALITY_PRIVATE_KEY}
SNI:              ${VLESS_SNI}

[Hysteria2 — UDP/${HY2_PORT}]
Password:         ${HYSTERIA_PASSWORD}
SNI:              ${HY2_SNI}
Note:             UDP — use outside China only

[Hiddify Client URLs]
VLESS (primary — use inside China):
${VLESS_URL}

Hysteria2 (backup — outside China / non-throttled UDP only):
${HY2_URL}
EOF

chmod 600 "$SB_CREDS"

# ============================================================
# DONE
# ============================================================
echo ""
echo -e "${CYAN}  ================================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${CYAN}  ================================================${NC}"
echo ""
echo -e "${YELLOW}  Credentials: cat ${SB_CREDS}${NC}"
echo ""
echo -e "${GREEN}  VLESS+Reality (primary):${NC}"
echo "  ${VLESS_URL}"
echo ""
echo -e "${GREEN}  Hysteria2 (backup):${NC}"
echo "  ${HY2_URL}"
echo ""
echo -e "${YELLOW}  Management:${NC}"
echo "  systemctl status sing-box"
echo "  journalctl -u sing-box -f"
echo "  systemctl restart sing-box"
echo ""

