#!/usr/bin/env bash
set -euo pipefail

# VPSGuard
# One-click Ubuntu LTS VPS initialization and SSH security hardening tool.
# Default user: alex
# Supported OS: Ubuntu LTS only

NEW_USER="${NEW_USER:-alex}"
SSH_PORT="${SSH_PORT:-}"
UFW_RESET_ENABLED="${UFW_RESET_ENABLED:-true}"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP_FILE=""
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
VPSGUARD_STATE_DIR="/etc/vpsguard"
VPSGUARD_CONFIG_FILE="/etc/vpsguard/config.env"
VPSGUARD_INSTALLED_MARKER="/etc/vpsguard/.installed"
VPSGUARD_SSH_DONE_MARKER="/etc/vpsguard/.ssh_done"
VPSGUARD_SUDO_DONE_MARKER="/etc/vpsguard/.sudo_done"
VPSGUARD_UFW_DONE_MARKER="/etc/vpsguard/.ufw_done"

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

ensure_state_dir() {
  mkdir -p "$VPSGUARD_STATE_DIR"
}

load_config_env() {
  if [ -f "$VPSGUARD_CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$VPSGUARD_CONFIG_FILE"
  fi

  NEW_USER="${NEW_USER:-alex}"
  SSH_PORT="${SSH_PORT:-22}"
  UFW_RESET_ENABLED="${UFW_RESET_ENABLED:-true}"
}

write_config_value() {
  local key="$1"
  local value="$2"

  if grep -q "^${key}=" "$VPSGUARD_CONFIG_FILE" 2>/dev/null; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$VPSGUARD_CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$VPSGUARD_CONFIG_FILE"
  fi
}

persist_config_env() {
  ensure_state_dir
  if [ ! -f "$VPSGUARD_CONFIG_FILE" ]; then
    printf '%s\n' "# VPSGuard config" > "$VPSGUARD_CONFIG_FILE"
  fi

  write_config_value "NEW_USER" "$NEW_USER"
  write_config_value "SSH_PORT" "$SSH_PORT"
  write_config_value "UFW_RESET_ENABLED" "$UFW_RESET_ENABLED"
  chmod 600 "$VPSGUARD_CONFIG_FILE"
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
  local detected_port

  if [ -f "$VPSGUARD_CONFIG_FILE" ] && [ -n "${SSH_PORT:-}" ]; then
    info "Using configured SSH port: $SSH_PORT"
    return
  fi

  detected_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"

  if [ -z "$detected_port" ]; then
    detected_port="22"
  fi

  if [ -z "${SSH_PORT:-}" ] || [ ! -f "$VPSGUARD_CONFIG_FILE" ]; then
    SSH_PORT="$detected_port"
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

enable_bbr() {
  local sysctl_file="/etc/sysctl.d/99-bbr.conf"
  local current_cc
  local current_qdisc

  info "Enabling BBR network acceleration..."

  if ! modprobe tcp_bbr >/dev/null 2>&1; then
    warn "tcp_bbr module could not be loaded. Kernel may not support BBR; continuing."
    return 0
  fi

  cat > "$sysctl_file" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || warn "Failed to apply net.core.default_qdisc=fq immediately."
  sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || warn "Failed to apply net.ipv4.tcp_congestion_control=bbr immediately."

  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

  if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
    info "BBR enabled: tcp_congestion_control=bbr, default_qdisc=fq"
  else
    warn "BBR was configured but is not fully active yet. Current: tcp_congestion_control=${current_cc:-unknown}, default_qdisc=${current_qdisc:-unknown}"
  fi
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
}

configure_sudo() {
  info "Configuring passwordless sudo for $NEW_USER..."
  cat >"/etc/sudoers.d/90-${NEW_USER}" <<EOF
${NEW_USER} ALL=(ALL) NOPASSWD: ALL
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
  chmod 700 "/home/${NEW_USER}/.ssh"

  if [ ! -s /root/.ssh/authorized_keys ]; then
    error "Root authorized_keys is missing or empty."
  fi

  touch "/home/${NEW_USER}/.ssh/authorized_keys"
  awk 'NF && !seen[$0]++' /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys" > "/home/${NEW_USER}/.ssh/authorized_keys.tmp"
  mv "/home/${NEW_USER}/.ssh/authorized_keys.tmp" "/home/${NEW_USER}/.ssh/authorized_keys"

  chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"
  chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"

  info "SSH key entries synced to /home/${NEW_USER}/.ssh/authorized_keys"
}

test_sudo_user() {
  info "Testing sudo permission for $NEW_USER..."

  if sudo -u "$NEW_USER" sudo -n -i true >/dev/null 2>&1; then
    info "$NEW_USER can use passwordless sudo -i successfully."
  else
    error "$NEW_USER sudo test failed. Stop before changing SSH settings."
  fi
}

configure_ufw() {
  info "Configuring UFW firewall..."

  info "Allowing SSH port only: ${SSH_PORT}/tcp"
  mkdir -p "$VPSGUARD_STATE_DIR"

  if [ -f "$VPSGUARD_UFW_DONE_MARKER" ]; then
    warn "UFW phase already completed. Skipping firewall changes."
    return 0
  fi

  if [ -f "$VPSGUARD_INSTALLED_MARKER" ]; then
    warn "VPSGuard is already installed. Skipping destructive firewall changes."
  fi

  if ufw status 2>/dev/null | grep -q "^Status: active"; then
    warn "UFW is already active. Preserving existing rules."
    if ! ufw status numbered 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
      ufw allow "${SSH_PORT}/tcp" || warn "Could not add SSH allow rule, please verify UFW manually."
    fi
  else
    if [ "${UFW_RESET_ENABLED}" = "true" ] && [ ! -f "$VPSGUARD_INSTALLED_MARKER" ]; then
      info "First run detected. Applying fresh UFW rules."
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
    else
      warn "UFW reset disabled or this is a re-run. Skipping reset and preserving existing rules."
    fi

    if ! ufw status numbered 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
      ufw allow "${SSH_PORT}/tcp"
    fi
    ufw --force enable
  fi

  touch "$VPSGUARD_UFW_DONE_MARKER"

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
  SSHD_BACKUP_FILE="/etc/ssh/sshd_config.bak.vpsguard"

  if [ -f "$SSHD_BACKUP_FILE" ]; then
    info "SSH config backup already exists: $SSHD_BACKUP_FILE"
    return 0
  fi

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
  echo -e "${YELLOW}${BOLD}Then test passwordless sudo:${NC}"
  echo
  echo -e "  ${BOLD}sudo -i${NC}"
  echo
  echo -e "${YELLOW}${BOLD}Expected output:${NC}"
  echo
  echo -e "  ${GREEN}${BOLD}A root shell prompt without a password prompt${NC}"
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

phase_1_preflight_checks() {
  require_root
  check_ubuntu_lts
}

phase_2_config_loading() {
  ensure_state_dir
  load_config_env
  detect_ssh_port
  persist_config_env
}

phase_3_user_setup() {
  if [ -f "$VPSGUARD_SSH_DONE_MARKER" ]; then
    info "Phase 3 already completed. Skipping user setup."
    return 0
  fi

  check_root_ssh_key
  upgrade_system
  create_user
  setup_ssh_key
  touch "$VPSGUARD_SSH_DONE_MARKER"
}

phase_4_ssh_hardening() {
  if [ -f "$VPSGUARD_INSTALLED_MARKER" ]; then
    info "SSH hardening already applied. Skipping."
    return 0
  fi

  harden_ssh
  configure_fail2ban
}

phase_5_sudo_configuration() {
  if [ -f "$VPSGUARD_SUDO_DONE_MARKER" ]; then
    info "Sudo configuration already completed. Skipping."
    return 0
  fi

  configure_sudo
  test_sudo_user
  touch "$VPSGUARD_SUDO_DONE_MARKER"
}

phase_6_firewall_configuration() {
  configure_ufw
}

phase_7_validation() {
  final_check
  touch "$VPSGUARD_INSTALLED_MARKER"
}

main() {
  phase_1_preflight_checks
  phase_2_config_loading
  phase_3_user_setup
  enable_bbr
  phase_4_ssh_hardening
  phase_5_sudo_configuration
  phase_6_firewall_configuration
  phase_7_validation
}

main "$@"
