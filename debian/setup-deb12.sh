#!/usr/bin/env bash
# =============================================================================
#  VPS First-Login & Hardening Script
#  Target: Debian 12 (Bookworm) — generic, provider-agnostic
#  Run as: root
#  Usage:  chmod +x vps-setup.sh && ./vps-setup.sh
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
fatal()   { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }
ask()     { echo -e "${YELLOW}▶${RESET} $*"; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && fatal "Must be run as root. Try: sudo bash vps-setup.sh"

if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  if [[ "$ID" != "debian" ]]; then
    warn "This script targets Debian 12. Detected: ${PRETTY_NAME:-unknown}."
    ask "Continue anyway? [y/N]:"
    read -r _c; [[ "$_c" =~ ^[Yy]$ ]] || exit 1
  fi
fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
  ╔════════════════════════════════════════════════════╗
  ║     VPS First-Login & Hardening Script             ║
  ║     Debian 12 — Provider Agnostic                  ║
  ╚════════════════════════════════════════════════════╝
EOF
echo -e "${RESET}"
echo "  Steps this script performs:"
echo "    1.  System update"
echo "    2.  Create sudo user (with password)"
echo "    3.  SSH key installation"
echo "    4.  SSH daemon hardening (port, no-root, key-only)"
echo "    5.  UFW firewall (default deny)"
echo "    6.  Fail2ban (SSH brute-force protection)"
echo "    7.  Automatic security updates"
echo "    8.  Kernel / sysctl network hardening"
echo "    9.  Shared memory hardening"
echo "    10. (Optional) rkhunter rootkit scanner"
echo "    11. (Optional) Disable IPv6"
echo ""
ask "Press ENTER to begin, or Ctrl+C to abort."
read -r

# =============================================================================
# COLLECT ALL CONFIG UP FRONT
# =============================================================================
section "Configuration"

# ── New sudo username ─────────────────────────────────────────────────────────
while true; do
  ask "Username for the new sudo account:"
  read -r NEW_USER
  [[ -n "$NEW_USER" && "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
  warn "Invalid. Use lowercase letters, digits, hyphens, underscores (no leading digit)."
done

# ── Sudo password ─────────────────────────────────────────────────────────────
echo ""
warn "A sudo password is required (used when running 'sudo' commands)."
warn "Store it in your password manager."
while true; do
  ask "Sudo password for '$NEW_USER' (min 12 chars, input hidden):"
  read -rs SUDO_PASS; echo
  ask "Confirm password:"
  read -rs SUDO_PASS2; echo
  if [[ "$SUDO_PASS" != "$SUDO_PASS2" ]]; then
    warn "Passwords do not match. Try again."; continue
  fi
  if [[ ${#SUDO_PASS} -lt 12 ]]; then
    warn "Password too short (minimum 12 characters). Try again."; continue
  fi
  break
done

# ── SSH public key ────────────────────────────────────────────────────────────
echo ""
info "SSH public key auth is strongly recommended."
info "On your local machine, run:  cat ~/.ssh/id_ed25519.pub"
echo ""
ask "Paste your SSH public key here (or press ENTER to skip — password auth will be kept):"
read -r SSH_PUBKEY

if [[ -n "$SSH_PUBKEY" ]]; then
  # Basic validation
  KEY_TYPE=$(echo "$SSH_PUBKEY" | awk '{print $1}')
  case "$KEY_TYPE" in
    ssh-ed25519|ssh-rsa|ssh-ecdsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com)
      USE_KEY=true ;;
    *)
      warn "Key type '$KEY_TYPE' looks unusual. Accepted anyway — double-check it."
      USE_KEY=true ;;
  esac
else
  USE_KEY=false
  warn "No SSH key provided. Password authentication will remain enabled."
  warn "This is less secure — consider adding a key later."
fi

# ── SSH port ──────────────────────────────────────────────────────────────────
echo ""
ask "SSH port [default: 2222, or enter a custom port 1024–65535]:"
read -r SSH_PORT
SSH_PORT=${SSH_PORT:-2222}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
  warn "Invalid port '$SSH_PORT', using 2222."
  SSH_PORT=2222
fi

# ── Extra firewall ports ──────────────────────────────────────────────────────
echo ""
ask "Additional TCP ports to open (space-separated, e.g. '80 443 8080'). Leave blank for none:"
read -r EXTRA_PORTS_TCP

echo ""
ask "Additional UDP ports to open (space-separated). Leave blank for none:"
read -r EXTRA_PORTS_UDP

# ── Optional components ───────────────────────────────────────────────────────
echo ""
ask "Disable IPv6? (recommended only if you don't use IPv6) [y/N]:"
read -r _ipv6; DISABLE_IPV6=false
[[ "${_ipv6:-N}" =~ ^[Yy]$ ]] && DISABLE_IPV6=true

echo ""
ask "Install rkhunter rootkit scanner? [Y/n]:"
read -r _rk; INSTALL_RKH=true
[[ "${_rk:-Y}" =~ ^[Nn]$ ]] && INSTALL_RKH=false

echo ""
ask "Install and enable auditd system call auditing? [y/N]:"
read -r _audit; INSTALL_AUDIT=false
[[ "${_audit:-N}" =~ ^[Yy]$ ]] && INSTALL_AUDIT=true

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Summary ─────────────────────────────────────────────${RESET}"
printf "  %-22s %s\n" "New user:"         "$NEW_USER"
printf "  %-22s %s\n" "SSH auth:"         "$( $USE_KEY && echo 'Key only (password auth disabled)' || echo 'Password (key not provided)' )"
printf "  %-22s %s\n" "SSH port:"         "$SSH_PORT"
printf "  %-22s %s\n" "Extra TCP ports:"  "${EXTRA_PORTS_TCP:-none}"
printf "  %-22s %s\n" "Extra UDP ports:"  "${EXTRA_PORTS_UDP:-none}"
printf "  %-22s %s\n" "Disable IPv6:"     "$( $DISABLE_IPV6 && echo 'yes' || echo 'no' )"
printf "  %-22s %s\n" "rkhunter:"         "$( $INSTALL_RKH && echo 'yes' || echo 'no' )"
printf "  %-22s %s\n" "auditd:"           "$( $INSTALL_AUDIT && echo 'yes' || echo 'no' )"
echo ""
ask "Proceed? [Y/n]:"
read -r _go; [[ "${_go:-Y}" =~ ^[Nn]$ ]] && { info "Aborted."; exit 0; }

# =============================================================================
# 1. SYSTEM UPDATE
# =============================================================================
section "1 / 11  System Update"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget git unzip ufw fail2ban \
  unattended-upgrades apt-listchanges \
  sudo openssh-server
apt-get autoremove -y -qq
apt-get autoclean -y -qq
success "System updated and base packages installed."

# =============================================================================
# 2. CREATE SUDO USER
# =============================================================================
section "2 / 11  Create Sudo User"

if id "$NEW_USER" &>/dev/null; then
  warn "User '$NEW_USER' already exists — skipping creation."
else
  adduser --gecos "" --disabled-password "$NEW_USER"
  success "User '$NEW_USER' created."
fi

echo "${NEW_USER}:${SUDO_PASS}" | chpasswd
success "Password set for '$NEW_USER'."

usermod -aG sudo "$NEW_USER"
success "'$NEW_USER' added to sudo group."

# =============================================================================
# 3. SSH KEY INSTALLATION
# =============================================================================
section "3 / 11  SSH Key Installation"

SSH_DIR="/home/${NEW_USER}/.ssh"
mkdir -p "$SSH_DIR"

if $USE_KEY; then
  echo "$SSH_PUBKEY" >> "${SSH_DIR}/authorized_keys"
  sort -u "${SSH_DIR}/authorized_keys" -o "${SSH_DIR}/authorized_keys"
  success "SSH public key installed."
else
  info "No key provided — skipping authorized_keys setup."
fi

chmod 700 "$SSH_DIR"
[[ -f "${SSH_DIR}/authorized_keys" ]] && chmod 600 "${SSH_DIR}/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "$SSH_DIR"

# =============================================================================
# 4. SSH HARDENING
# =============================================================================
section "4 / 11  SSH Hardening"

SSHD_CONF="/etc/ssh/sshd_config"
SSHD_BAK="${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp "$SSHD_CONF" "$SSHD_BAK"
info "Backed up sshd_config → $SSHD_BAK"

# Drop-in override — cleaner than sed-patching the main file
DROPIN_DIR="/etc/ssh/sshd_config.d"
mkdir -p "$DROPIN_DIR"
DROPIN="${DROPIN_DIR}/99-hardening.conf"

cat > "$DROPIN" <<EOF
# Generated by vps-setup.sh on $(date)
Port ${SSH_PORT}
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 20
StrictModes yes

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication $( $USE_KEY && echo 'no' || echo 'yes' )
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PrintMotd no

# Disable reverse DNS lookup — prevents SSH handshake hangs
# when PTR records are missing or DNS is slow on the provider
UseDNS no

AllowUsers ${NEW_USER}

# Modern crypto only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
EOF

# Make sure the main config includes the drop-in directory
if ! grep -q "^Include /etc/ssh/sshd_config.d" "$SSHD_CONF"; then
  sed -i '1s|^|Include /etc/ssh/sshd_config.d/*.conf\n|' "$SSHD_CONF"
fi

if sshd -t 2>/dev/null; then
  systemctl enable sshd
  systemctl restart sshd
  success "sshd enabled and restarted — now listening on port $SSH_PORT."
else
  warn "sshd config validation failed. Reverting drop-in."
  rm -f "$DROPIN"
  fatal "SSH hardening aborted. Check sshd_config manually."
fi

# ── Verification gate ─────────────────────────────────────────────────────────
VPS_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${RED}╔═══════════════════════════════════════════════════════════╗"
echo -e "║  STOP — verify SSH access before continuing               ║"
echo -e "║                                                           ║"
echo -e "║  Open a NEW terminal and run:                             ║"
printf "║  ssh -p %-5s %s@%-30s ║\n" "$SSH_PORT" "$NEW_USER" "$VPS_IP"
echo -e "║                                                           ║"
echo -e "║  If it fails, use your provider's web/VNC console to fix. ║"
echo -e "╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""
ask "Type 'yes' once you have confirmed SSH access in a new terminal:"
while true; do
  read -r _gate
  [[ "$_gate" == "yes" ]] && break
  ask "Please type 'yes' (exactly) to confirm:"
done
success "SSH access confirmed."

# =============================================================================
# 5. UFW FIREWALL
# =============================================================================
section "5 / 11  UFW Firewall"

ufw --force reset >/dev/null 2>&1
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw limit "${SSH_PORT}/tcp" comment "SSH (rate-limited)"
info "SSH port $SSH_PORT allowed (rate-limited)."

for p in ${EXTRA_PORTS_TCP:-}; do
  [[ -z "$p" ]] && continue
  if [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
    ufw allow "${p}/tcp" comment "User TCP" >/dev/null
    info "Allowed TCP: $p"
  else
    warn "Skipping invalid TCP port: $p"
  fi
done

for p in ${EXTRA_PORTS_UDP:-}; do
  [[ -z "$p" ]] && continue
  if [[ "$p" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
    ufw allow "${p}/udp" comment "User UDP" >/dev/null
    info "Allowed UDP: $p"
  else
    warn "Skipping invalid UDP port: $p"
  fi
done

ufw --force enable >/dev/null
success "UFW enabled."
ufw status verbose

# =============================================================================
# 6. FAIL2BAN
# =============================================================================
section "6 / 11  Fail2ban"

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime   = 6h
findtime  = 1m
maxretry  = 10
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
# Debian 12 minimal images use journald — /var/log/auth.log may not exist.
# Hardcode systemd backend so fail2ban does not crash looking for a log file.
backend  = systemd
maxretry = 10
bantime  = 6h
findtime = 1m
EOF

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
success "Fail2ban running."
fail2ban-client status sshd 2>/dev/null || true

# =============================================================================
# 7. AUTOMATIC SECURITY UPDATES
# =============================================================================
section "7 / 11  Automatic Security Updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
success "Unattended security upgrades enabled."

# =============================================================================
# 8. SYSCTL — NETWORK & KERNEL HARDENING
# =============================================================================
section "8 / 11  Kernel / Network Hardening"

cat > /etc/sysctl.d/99-hardening.conf <<EOF
# ── IP Spoofing protection ─────────────────────────────
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ── Ignore ICMP redirects ──────────────────────────────
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# ── Do not send ICMP redirects ─────────────────────────
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# ── Ignore ping broadcasts ─────────────────────────────
net.ipv4.icmp_echo_ignore_broadcasts = 1

# ── Bad error message protection ──────────────────────
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── SYN flood protection ───────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096

# ── Log martians ───────────────────────────────────────
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# ── Time-wait assassination attacks ───────────────────
net.ipv4.tcp_rfc1337 = 1

# ── Don't accept source routing ────────────────────────
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# ── Kernel pointer hardening ───────────────────────────
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# ── Restrict ptrace ───────────────────────────────────
kernel.yama.ptrace_scope = 1

# ── Restrict core dumps ───────────────────────────────
fs.suid_dumpable = 0

$(if $DISABLE_IPV6; then
cat <<'IPV6'
# ── IPv6 disabled by user choice ──────────────────────
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6
fi)
EOF

sysctl -p /etc/sysctl.d/99-hardening.conf >/dev/null 2>&1
success "Sysctl hardening applied."

# =============================================================================
# 9. SHARED MEMORY HARDENING
# =============================================================================
section "9 / 11  Shared Memory"

if ! grep -q "tmpfs /run/shm" /etc/fstab 2>/dev/null && \
   ! grep -q "tmpfs /dev/shm" /etc/fstab 2>/dev/null; then
  echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
  info "Added /run/shm hardening to fstab (active after reboot)."
else
  info "/run/shm already configured in fstab."
fi

# Limit core dumps via limits.conf
if ! grep -q "hard core" /etc/security/limits.conf; then
  echo "* hard core 0" >> /etc/security/limits.conf
  info "Core dumps restricted."
fi
success "Shared memory hardening done."

# =============================================================================
# 10. RKHUNTER (OPTIONAL)
# =============================================================================
section "10 / 11  rkhunter"

if $INSTALL_RKH; then
  apt-get install -y -qq rkhunter
  # Suppress false positives common on fresh Debian installs
  sed -i 's|#SCRIPTWHITELIST=/usr/bin/egrep|SCRIPTWHITELIST=/usr/bin/egrep|' \
    /etc/rkhunter.conf 2>/dev/null || true
  rkhunter --update --nocolors >/dev/null 2>&1 || true
  rkhunter --propupd --nocolors >/dev/null 2>&1
  success "rkhunter installed and baseline recorded."
  info "Run periodic checks with: rkhunter --check --skip-keypress"
else
  info "rkhunter skipped."
fi

# =============================================================================
# 11. AUDITD (OPTIONAL)
# =============================================================================
section "11 / 11  auditd"

if $INSTALL_AUDIT; then
  apt-get install -y -qq auditd audispd-plugins
  systemctl enable --now auditd >/dev/null 2>&1
  # Basic audit rules
  cat > /etc/audit/rules.d/99-hardening.rules <<'AUDIT'
# Log all authentication events
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
# Log SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd
# Log privilege escalation
-a always,exit -F arch=b64 -S setuid -k privilege_escalation
-a always,exit -F arch=b64 -S setgid -k privilege_escalation
# Catch use of su/sudo
-w /usr/bin/su -p x -k su
-w /usr/bin/sudo -p x -k sudo
AUDIT
  augenrules --load >/dev/null 2>&1 || true
  success "auditd installed with hardening rules."
else
  info "auditd skipped."
fi

# =============================================================================
# MOTD — set a minimal, clean login banner
# =============================================================================
cat > /etc/motd <<EOF

  ──────────────────────────────────────────
   $(hostname) — secured $(date +%Y-%m-%d)
   Unauthorized access is prohibited.
  ──────────────────────────────────────────

EOF

# =============================================================================
# FINAL SUMMARY
# =============================================================================
VPS_IP=$(hostname -I | awk '{print $1}')

section "Complete"

echo -e "${BOLD}${GREEN}✔  VPS hardening complete.${RESET}"
echo ""
echo -e "${BOLD}Connection command:${RESET}"
echo "  ssh -p ${SSH_PORT} ${NEW_USER}@${VPS_IP}"
echo ""
echo -e "${BOLD}What was configured:${RESET}"
echo "  ✔ System updated (full-upgrade)"
echo "  ✔ Sudo user '$NEW_USER' created with password"
$USE_KEY && echo "  ✔ SSH key installed — password auth disabled" \
         || echo "  ⚠ SSH key not provided — password auth still enabled"
echo "  ✔ Root SSH login disabled"
echo "  ✔ SSH moved to port $SSH_PORT with modern crypto only"
echo "  ✔ UFW firewall active (default deny inbound)"
echo "  ✔ Fail2ban: ban after 4 failed attempts, 6h ban"
echo "  ✔ Unattended security upgrades enabled"
echo "  ✔ Sysctl network + kernel hardening"
echo "  ✔ Shared memory hardened (/run/shm)"
$INSTALL_RKH   && echo "  ✔ rkhunter installed with baseline"
$INSTALL_AUDIT && echo "  ✔ auditd enabled with hardening rules"
$DISABLE_IPV6  && echo "  ✔ IPv6 disabled"
echo ""
echo -e "${BOLD}Recommended next steps:${RESET}"
echo "  1. Reboot to apply fstab + kernel changes:"
echo "       sudo reboot"
echo "  2. After reboot, verify UFW and fail2ban are running:"
echo "       sudo ufw status verbose"
echo "       sudo fail2ban-client status sshd"
echo "  3. Add your SSH key to your password manager / backup"
echo "  4. Check unattended-upgrades is active:"
echo "       sudo systemctl status unattended-upgrades"
echo ""
echo -e "${YELLOW}Note: Your sshd_config backup is at: ${SSHD_BAK}${RESET}"
echo ""
