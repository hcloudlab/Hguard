#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
NC="\033[0m"
NEW_USER="${NEW_USER:-alex}"

info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  error "Please run this script as root."
fi

echo
warn "This will disable UFW and fail2ban."
warn "It will NOT automatically re-enable root login or SSH password login."
warn "It will NOT delete the ${NEW_USER} user."
echo
echo -e "${RED}${BOLD}Use this only when you understand the impact.${NC}"
echo

read -r -p "Continue? [y/N]: " confirm

case "$confirm" in
  y|Y|yes|YES)
    ;;
  *)
    echo "Cancelled."
    exit 0
    ;;
esac

if systemctl is-active --quiet fail2ban; then
  info "Stopping fail2ban..."
  systemctl stop fail2ban
fi

if systemctl is-enabled --quiet fail2ban; then
  info "Disabling fail2ban..."
  systemctl disable fail2ban
fi

if [ -f /etc/fail2ban/jail.d/sshd.local ]; then
  info "Removing /etc/fail2ban/jail.d/sshd.local..."
  rm -f /etc/fail2ban/jail.d/sshd.local
fi

if command -v ufw >/dev/null 2>&1; then
  info "Disabling UFW..."
  ufw --force disable
fi

info "Uninstall completed."
echo
echo "SSH configuration was not changed."
echo "User ${NEW_USER} was not deleted."
echo
echo "To manually edit SSH config:"
echo "  nano /etc/ssh/sshd_config"
echo "  sshd -t"
echo "  systemctl reload ssh"
