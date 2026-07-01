#!/usr/bin/env bash
set -euo pipefail

# VPSGuard
# One-click Ubuntu LTS VPS initialization and SSH security hardening tool.
# Default user: alex
# Supported OS: Ubuntu LTS only

NEW_USER="${NEW_USER:-alex}"
SSH_PORT="${SSH_PORT:-}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP_FILE=""
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
VPSGUARD_STATE_DIR="/etc/vpsguard"
VPSGUARD_INITIALIZED_MARKER="/etc/vpsguard/.initialized"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
BOLD="\033[1m"
NC="\033[0m"

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

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Please run this script as root."
  fi
}

check_ubuntu_lts() {
  if [ ! -f /etc/os-release ]; then
    error "Cannot detect OS. /etc/os-release not found."
  fi

  # shellcheck disable=SC1091
  . /etc/os-release

  if [ "${ID:-}" != "ubuntu" ]; then
    error "Unsupported OS: ${PRETTY_NAME:-unknown}. VPSGuard supports Ubuntu LTS only."
  fi

  if ! echo "${VERSION:-}" | grep -qi "LTS"; then
    error "Unsupported Ubuntu version: ${PRETTY_NAME:-unknown}. Please use Ubuntu LTS."
  fi

  info "Detected supported OS: ${PRETTY_NAME}"
}

detect_ssh_port() {
  if [ -n "$SSH_PORT" ]; then
    info "Using custom SSH port: $SSH_PORT"
    return
  fi

  SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"

  if [ -z "$SSH_PORT" ]; then
    SSH_PORT="22"
  fi

  info "Detected SSH port: $SSH_PORT"
}

check_root_ssh_key() {
  if [ ! -s /root/.ssh/authorized_keys ]; then
    error "Root SSH public key is missing.
Please add your SSH public key to /root/.ssh/authorized_keys before running VPSGuard.
Do not paste your private key into the VPS.
For Termius: Keychain → Key → Public Key → Copy.

未检测到 root 的 SSH 公钥。
请先把你的 SSH 公钥添加到 /root/.ssh/authorized_keys 后再运行 VPSGuard。
不要把私钥粘贴到 VPS。
Termius 用户：Keychain → Key → Public Key → Copy，复制 Public Key。"
  fi

  info "Root SSH authorized_keys found."
}

upgrade_system() {
  info "Updating system packages..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y

  info "Installing basic tools..."
  DEBIAN_FRONTEND=noninteractive apt install -y \
    sudo \
    curl \
    wget \
    git \
    vim \
    nano \
    unzip \
    ufw \
    fail2ban \
    htop \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    net-tools \
    iproute2 \
    openssh-server
}

create_user() {
  if id "$NEW_USER" >/dev/null 2>&1; then
    warn "User $NEW_USER already exists. Skipping user creation."
  else
    info "Creating user: $NEW_USER"
    adduser --disabled-password --gecos "" "$NEW_USER"
  fi

  info "Adding $NEW_USER to sudo group..."
  usermod -aG sudo "$NEW_USER"

  local systemctl_bin
  local ufw_bin
  local journalctl_bin

  systemctl_bin="$(command -v systemctl || true)"
  ufw_bin="$(command -v ufw || true)"
  journalctl_bin="$(command -v journalctl || true)"

  if [ -z "$systemctl_bin" ] || [ -z "$ufw_bin" ] || [ -z "$journalctl_bin" ]; then
    error "Required admin commands were not found in PATH. Cannot configure restricted sudo safely."
  fi

  info "Configuring restricted passwordless sudo for $NEW_USER..."
  cat >"/etc/sudoers.d/90-${NEW_USER}" <<EOF
${NEW_USER} ALL=(ALL) NOPASSWD: ${systemctl_bin}, ${ufw_bin}, ${journalctl_bin}
EOF

  chmod 440 "/etc/sudoers.d/90-${NEW_USER}"

  if visudo -cf "/etc/sudoers.d/90-${NEW_USER}" >/dev/null; then
    info "Sudoers file is valid."
  else
    error "Sudoers validation failed."
  fi
}

setup_ssh_key() {
  info "Configuring SSH key for $NEW_USER..."

  mkdir -p "/home/${NEW_USER}/.ssh"
  cp /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"

  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 700 "/home/${NEW_USER}/.ssh"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"

  info "SSH key copied to /home/${NEW_USER}/.ssh/authorized_keys"
}

test_sudo_user() {
  info "Testing sudo permission for $NEW_USER..."

  if sudo -u "$NEW_USER" sudo -n "$(command -v ufw)" status >/dev/null 2>&1; then
    info "$NEW_USER can use restricted sudo successfully."
  else
    error "$NEW_USER sudo test failed. Stop before changing SSH settings."
  fi
}

configure_ufw() {
  info "Configuring UFW firewall..."

  info "Allowing SSH port only: ${SSH_PORT}/tcp"
  mkdir -p "$VPSGUARD_STATE_DIR"

  if [ -f "$VPSGUARD_INITIALIZED_MARKER" ] || ufw status 2>/dev/null | grep -q "^Status: active"; then
    warn "UFW is already initialized or active. Skipping reset to preserve existing firewall rules."
    ufw allow "${SSH_PORT}/tcp" || warn "Could not re-apply SSH port allow rule, please verify UFW manually."
    touch "$VPSGUARD_INITIALIZED_MARKER"
    if ufw status 2>/dev/null | grep -q "^Status: inactive"; then
      info "UFW is inactive. Enabling without resetting existing rules."
      ufw --force enable
    fi
  else
    info "First run detected. Applying fresh UFW rules."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"
    ufw --force enable
    touch "$VPSGUARD_INITIALIZED_MARKER"
  fi

  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "UFW enabled. SSH port ${SSH_PORT}/tcp is allowed."
  else
    warn "UFW is not active. Please verify firewall status manually."
  fi

  ufw status verbose || true
}

configure_fail2ban() {
  info "Configuring fail2ban for SSH..."

  cat >"$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  sleep 3

  info "fail2ban configured."
  fail2ban-client status sshd || warn "fail2ban sshd status check failed."
}

backup_sshd_config() {
  SSHD_BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SSHD_CONFIG" "$SSHD_BACKUP_FILE"
  info "SSH config backup created: $SSHD_BACKUP_FILE"
}

set_sshd_option() {
  local key="$1"
  local value="$2"

  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$SSHD_CONFIG"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

verify_ssh_service_available() {
  systemctl is-active --quiet ssh.service || ss -tulpn | grep -q ":${SSH_PORT}"
}

ssh_service_error() {
  error "SSH service did not become available after applying hardened configuration.
Do NOT close this root session until SSH login is verified.
Please run:
systemctl status ssh --no-pager
systemctl status ssh.socket --no-pager
sshd -t
ss -tulpn | grep ':${SSH_PORT}'"
}

apply_ssh_service_changes() {
  local applied=0
  local success_message=""

  if systemctl is-active --quiet ssh.service; then
    if systemctl reload ssh.service; then
      applied=1
      success_message="SSH hardened and reloaded."
    elif systemctl restart ssh.service; then
      applied=1
      success_message="SSH hardened and restarted."
    fi
  elif systemctl is-active --quiet ssh.socket; then
    if systemctl restart ssh.service || systemctl start ssh.service; then
      applied=1
      success_message="SSH hardened and started via ssh.socket-compatible path."
    fi
  elif systemctl restart ssh.service; then
    applied=1
    success_message="SSH hardened and restarted."
  fi

  if [ "$applied" -eq 1 ] && verify_ssh_service_available; then
    if [ -n "$success_message" ]; then
      info "$success_message"
    else
      info "SSH hardened and listening on port ${SSH_PORT}."
    fi
  else
    ssh_service_error
  fi
}

harden_ssh() {
  info "Hardening SSH..."

  backup_sshd_config

  # Keep the current SSH port.
  # VPSGuard only allows this port in UFW to avoid accidental lockout.
  set_sshd_option "Port" "$SSH_PORT"

  # Disable direct root SSH login.
  # After this change, you should log in as the sudo user instead of root.
  set_sshd_option "PermitRootLogin" "no"

  # Enable SSH public key authentication.
  # This allows login with SSH keys, which is safer than password login.
  set_sshd_option "PubkeyAuthentication" "yes"

  # Disable SSH password authentication.
  # This blocks direct password-based SSH login and reduces brute-force risk.
  set_sshd_option "PasswordAuthentication" "no"

  # Disable keyboard-interactive authentication.
  # This prevents alternative interactive password prompts such as PAM challenge-response login.
  set_sshd_option "KbdInteractiveAuthentication" "no"

  # Disable empty password login.
  # This ensures users with empty passwords cannot log in through SSH.
  set_sshd_option "PermitEmptyPasswords" "no"

  # Disable X11 forwarding.
  # This reduces unnecessary SSH features and lowers the attack surface on a server.
  set_sshd_option "X11Forwarding" "no"

  mkdir -p /run/sshd
  chmod 755 /run/sshd

  if sshd -t; then
    info "SSH configuration test passed."
  else
    error "SSH configuration test failed.
Backup file: ${SSHD_BACKUP_FILE}
This can be caused by sshd_config syntax, missing runtime directories, or platform-specific SSH service requirements.
Please also check that /run/sshd exists and has correct permissions."
  fi

  apply_ssh_service_changes
}

final_check() {
  local server_ip
  server_ip="$(curl -4 --max-time 3 -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

  echo
  echo -e "${MAGENTA}${BOLD}============================================================${NC}"
  echo -e "${MAGENTA}${BOLD}                  VPSGuard Setup Completed                  ${NC}"
  echo -e "${MAGENTA}${BOLD}============================================================${NC}"
  echo
  echo -e "${CYAN}${BOLD}Final Configuration${NC}"
  echo -e "${BLUE}------------------------------------------------------------${NC}"
  echo -e "${GREEN}OS:${NC}                 $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
  echo -e "${GREEN}New sudo user:${NC}      ${BOLD}${NEW_USER}${NC}"
  echo -e "${GREEN}SSH port:${NC}           ${BOLD}${SSH_PORT}${NC}"
  echo -e "${GREEN}Root SSH login:${NC}     ${RED}${BOLD}Disabled${NC}"
  echo -e "${GREEN}Password SSH login:${NC} ${RED}${BOLD}Disabled${NC}"
  echo -e "${GREEN}SSH key login:${NC}      ${GREEN}${BOLD}Enabled${NC}"
  echo -e "${GREEN}UFW firewall:${NC}       ${GREEN}${BOLD}Enabled${NC}"
  echo -e "${GREEN}Allowed ports:${NC}      ${BOLD}${SSH_PORT}/tcp only${NC}"
  echo -e "${GREEN}fail2ban:${NC}           ${GREEN}${BOLD}Enabled${NC}"
  echo -e "${GREEN}fail2ban maxretry:${NC}  ${BOLD}5${NC}"
  echo -e "${GREEN}fail2ban findtime:${NC}  ${BOLD}10m${NC}"
  echo -e "${GREEN}fail2ban bantime:${NC}   ${BOLD}1h${NC}"
  echo -e "${BLUE}------------------------------------------------------------${NC}"
  echo
  echo -e "${YELLOW}${BOLD}Test new SSH login from your local computer:${NC}"
  echo
  echo -e "  ${BOLD}ssh ${NEW_USER}@${server_ip} -p ${SSH_PORT}${NC}"
  echo
  echo -e "${YELLOW}${BOLD}Then test restricted sudo:${NC}"
  echo
  echo -e "  ${BOLD}sudo ufw status verbose${NC}"
  echo
  echo -e "${YELLOW}${BOLD}Expected output:${NC}"
  echo
  echo -e "  ${GREEN}${BOLD}UFW status details or active rules${NC}"
  echo
  echo -e "${RED}${BOLD}IMPORTANT:${NC}"
  echo -e "${RED}${BOLD}Do NOT close this root session until the new ${NEW_USER} SSH login works.${NC}"
  echo
  echo -e "${CYAN}${BOLD}Useful status commands:${NC}"
  echo
  echo -e "  ${BOLD}sudo ufw status verbose${NC}"
  echo -e "  ${BOLD}sudo fail2ban-client status sshd${NC}"
  echo -e "  ${BOLD}sudo ss -tulpn${NC}"
  echo
  echo -e "${MAGENTA}${BOLD}============================================================${NC}"
  echo
}

main() {
  require_root
  check_ubuntu_lts
  detect_ssh_port
  check_root_ssh_key
  upgrade_system
  create_user
  setup_ssh_key
  test_sudo_user
  configure_ufw
  configure_fail2ban
  harden_ssh
  final_check
}

main "$@"
