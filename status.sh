#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
NC="\033[0m"
NEW_USER="${NEW_USER:-alex}"

info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

section() {
  echo
  echo -e "${CYAN}${BOLD}==> $1${NC}"
}

section "System information"
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime -p)"
echo "Kernel: $(uname -r)"

section "OS"
grep -E "PRETTY_NAME|VERSION_ID|VERSION=" /etc/os-release || true

section "User ${NEW_USER}"
id "${NEW_USER}" || warn "User ${NEW_USER} does not exist."

section "Sudo group"
getent group sudo || true

section "SSH effective configuration"
sshd -T 2>/dev/null | grep -Ei "^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitemptypasswords|x11forwarding)" || true

section "UFW status"
ufw status verbose || warn "UFW is not available or not active."

section "fail2ban sshd status"
fail2ban-client status sshd || warn "fail2ban sshd jail is not available."

section "Listening ports"
ss -tulpn

section "VPSGuard status check completed"
