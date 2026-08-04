#!/usr/bin/env bash
set -euo pipefail

# VPSGuard v0.3.5
# Ubuntu LTS initialization and SSH hardening with lockout-safe convergence.

VPSGUARD_VERSION="0.3.5"
VPSGUARD_TEST_MODE="${VPSGUARD_TEST_MODE:-0}"
VPSGUARD_ETC_ROOT="${VPSGUARD_ETC_ROOT:-/etc}"
VPSGUARD_RUN_ROOT="${VPSGUARD_RUN_ROOT:-/run}"
VPSGUARD_LOG_FILE="${VPSGUARD_LOG_FILE:-/var/log/vpsguard.log}"
VPSGUARD_STATE_DIR="${VPSGUARD_STATE_DIR:-${VPSGUARD_ETC_ROOT}/vpsguard}"
VPSGUARD_CONFIG_FILE="${VPSGUARD_CONFIG_FILE:-${VPSGUARD_STATE_DIR}/config.env}"
VPSGUARD_STATE_FILE="${VPSGUARD_STATE_FILE:-${VPSGUARD_STATE_DIR}/state.env}"
VPSGUARD_MANAGED_RULES="${VPSGUARD_MANAGED_RULES:-${VPSGUARD_STATE_DIR}/managed-rules}"
VPSGUARD_INSTALLED_MARKER="${VPSGUARD_INSTALLED_MARKER:-${VPSGUARD_STATE_DIR}/.installed}"
VPSGUARD_PENDING_PORT_MARKER="${VPSGUARD_PENDING_PORT_MARKER:-${VPSGUARD_STATE_DIR}/.pending-port-finalization}"

SSHD_CONFIG="${SSHD_CONFIG:-${VPSGUARD_ETC_ROOT}/ssh/sshd_config}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-${VPSGUARD_ETC_ROOT}/ssh/sshd_config.d}"
VPSGUARD_SSHD_CONFIG="${VPSGUARD_SSHD_CONFIG:-${SSHD_CONFIG_DIR}/00-vpsguard.conf}"
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-${VPSGUARD_ETC_ROOT}/systemd/system}"
VPSGUARD_SSH_SOCKET_OVERRIDE="${VPSGUARD_SSH_SOCKET_OVERRIDE:-${SYSTEMD_SYSTEM_DIR}/ssh.socket.d/00-vpsguard.conf}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-${VPSGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local}"
SUDOERS_DIR="${SUDOERS_DIR:-${VPSGUARD_ETC_ROOT}/sudoers.d}"
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-${VPSGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf}"
BBR_MODULES_FILE="${BBR_MODULES_FILE:-${VPSGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf}"
ROOT_AUTHORIZED_KEYS="${ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"

REQUESTED_NEW_USER="${NEW_USER:-}"
REQUESTED_SSH_PORT="${SSH_PORT:-}"
NEW_USER=""
PREVIOUS_MANAGED_USER=""
SSH_PORT=""
ORIGINAL_SSH_PORT=""
INSTALL_STATUS="failed"
BBR_STATUS="unsupported"
SSH_RUNTIME_MODE="unknown"
SSH_SERVICE_UNIT=""
FAIL2BAN_READY_ATTEMPTS=15
SSHD_INCLUDE_BEGIN="# BEGIN VPSGuard managed include"
SSHD_INCLUDE_END="# END VPSGuard managed include"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
NC="\033[0m"

log_plain() {
  local level="$1"
  local message="$2"

  if [ "$VPSGUARD_TEST_MODE" = "1" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$VPSGUARD_LOG_FILE")"
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$message" >> "$VPSGUARD_LOG_FILE"
  chmod 600 "$VPSGUARD_LOG_FILE"
}

info() {
  printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"
  log_plain INFO "$1"
}

warn() {
  printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"
  log_plain WARN "$1"
}

error() {
  printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2
  log_plain ERROR "$1"
  exit 1
}

ensure_directory() {
  local path="$1"
  local mode="${2:-700}"

  mkdir -p "$path"
  chmod "$mode" "$path"
  if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$path"
  fi
}

atomic_write() {
  local path="$1"
  local mode="$2"
  local content="$3"
  local directory
  local temporary_file

  directory="$(dirname "$path")"
  if [ ! -d "$directory" ]; then
    mkdir -p "$directory"
    chmod 755 "$directory"
    if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
      chown root:root "$directory"
    fi
  fi
  temporary_file="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$content" > "$temporary_file"
  chmod "$mode" "$temporary_file"
  if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$path"
}

assert_managed_or_absent() {
  local path="$1"
  if [ -e "$path" ] && ! head -n 1 "$path" | grep -Fq 'Managed by VPSGuard'; then
    error "Refusing to overwrite an unrecognized existing file: ${path}"
  fi
}

read_env_value() {
  local file="$1"
  local key="$2"
  local value

  [ -f "$file" ] || return 1
  value="$(awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file")"
  [ -n "$value" ] || return 1

  case "$value" in
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac

  printf '%s\n' "$value"
}

write_config_env() {
  local content

  content="# Managed by VPSGuard ${VPSGUARD_VERSION}; values are validated before use.
NEW_USER='${NEW_USER}'
SSH_PORT='${SSH_PORT}'
ORIGINAL_SSH_PORT='${ORIGINAL_SSH_PORT}'
INSTALL_STATUS='${INSTALL_STATUS}'
"
  atomic_write "$VPSGUARD_CONFIG_FILE" 600 "$content"
}

boolean_command_state() {
  if "$@" >/dev/null 2>&1; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

record_preinstall_state() {
  local ufw_installed ufw_active fail2ban_installed fail2ban_active fail2ban_enabled
  local sshd_dropin_preexisting sshd_include_preexisting ssh_socket_override_preexisting
  local fail2ban_jail_preexisting bbr_sysctl_preexisting bbr_modules_preexisting
  local content

  if [ -f "$VPSGUARD_STATE_FILE" ]; then
    info "Pre-install state already recorded; preserving the original snapshot."
    return 0
  fi

  ufw_installed="$(boolean_command_state command -v ufw)"
  fail2ban_installed="$(boolean_command_state command -v fail2ban-client)"
  ufw_active="false"
  fail2ban_active="false"
  fail2ban_enabled="false"

  if [ "$ufw_installed" = "true" ] && ufw status 2>/dev/null | awk 'NR == 1 && tolower($2) == "active" {found=1} END {exit !found}'; then
    ufw_active="true"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    fail2ban_active="$(boolean_command_state systemctl is-active --quiet fail2ban.service)"
    fail2ban_enabled="$(boolean_command_state systemctl is-enabled --quiet fail2ban.service)"
  fi

  sshd_dropin_preexisting="$(boolean_command_state test -e "$VPSGUARD_SSHD_CONFIG")"
  sshd_include_preexisting="$(boolean_command_state grep -Fqx "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"
  ssh_socket_override_preexisting="$(boolean_command_state test -e "$VPSGUARD_SSH_SOCKET_OVERRIDE")"
  fail2ban_jail_preexisting="$(boolean_command_state test -e "$FAIL2BAN_JAIL")"
  bbr_sysctl_preexisting="$(boolean_command_state test -e "$BBR_SYSCTL_FILE")"
  bbr_modules_preexisting="$(boolean_command_state test -e "$BBR_MODULES_FILE")"

  content="# VPSGuard pre-install state. Parsed as data; never sourced.
UFW_INSTALLED='${ufw_installed}'
UFW_ACTIVE='${ufw_active}'
FAIL2BAN_INSTALLED='${fail2ban_installed}'
FAIL2BAN_ACTIVE='${fail2ban_active}'
FAIL2BAN_ENABLED='${fail2ban_enabled}'
SSHD_DROPIN_PREEXISTED='${sshd_dropin_preexisting}'
SSHD_INCLUDE_PREEXISTED='${sshd_include_preexisting}'
SSH_SOCKET_OVERRIDE_PREEXISTED='${ssh_socket_override_preexisting}'
FAIL2BAN_JAIL_PREEXISTED='${fail2ban_jail_preexisting}'
BBR_SYSCTL_PREEXISTED='${bbr_sysctl_preexisting}'
BBR_MODULES_PREEXISTED='${bbr_modules_preexisting}'
"
  atomic_write "$VPSGUARD_STATE_FILE" 600 "$content"
  atomic_write "$VPSGUARD_MANAGED_RULES" 600 "# UFW rules added by VPSGuard
"
  info "Recorded pre-install service and managed-file state."
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Please run VPSGuard as root."
  fi
}

check_ubuntu_lts() {
  local os_release="${VPSGUARD_ETC_ROOT}/os-release"

  [ -f "$os_release" ] || error "Cannot detect Ubuntu: ${os_release} is missing."
  # shellcheck disable=SC1090
  . "$os_release"
  [ "${ID:-}" = "ubuntu" ] || error "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu LTS is required."
  printf '%s' "${VERSION:-}" | grep -qi 'LTS' || error "Unsupported Ubuntu release: ${PRETTY_NAME:-unknown}."
  info "Detected Ubuntu LTS: ${PRETTY_NAME:-unknown}"
}

validate_username() {
  local username="${1:-}"
  local reserved

  [ -n "$username" ] || return 1
  [ "${#username}" -le 32 ] || return 1
  [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1

  for reserved in root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc gnats nobody systemd-network systemd-timesync messagebus syslog _apt tss uuidd tcpdump sshd; do
    [ "$username" != "$reserved" ] || return 1
  done
}

validate_existing_user_account() {
  local username="$1"
  local passwd_entry uid home shell

  if ! passwd_entry="$(getent passwd "$username" 2>/dev/null)"; then
    passwd_entry=""
  fi
  [ -n "$passwd_entry" ] || return 0
  uid="$(printf '%s\n' "$passwd_entry" | awk -F: '{print $3}')"
  home="$(printf '%s\n' "$passwd_entry" | awk -F: '{print $6}')"
  shell="$(printf '%s\n' "$passwd_entry" | awk -F: '{print $7}')"

  [ "$uid" -ge 1000 ] || error "Existing account ${username} is a system account (UID ${uid})."
  if [ -z "$home" ] || [ "$home" = "/" ]; then
    error "Existing account ${username} has an unsafe home directory."
  fi
  case "$shell" in
    */false|*/nologin|'') error "Existing account ${username} does not have a login shell." ;;
  esac
}

prompt_for_username() {
  local candidate

  while true; do
    read -r -p "请输入要创建的管理员用户名：" candidate
    if validate_username "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    warn "用户名无效：请使用小写字母或下划线开头，只包含小写字母、数字、下划线和连字符，最长 32 字符，且不能使用系统账户。" >&2
  done
}

confirm_existing_user() {
  local username="$1"
  local answer

  info "User ${username} already exists. VPSGuard will preserve its password, home and existing SSH keys."
  if [ ! -t 0 ]; then
    return 0
  fi

  read -r -p "输入 YES 使用现有用户 ${username}，其他输入取消：" answer
  [ "$answer" = "YES" ] || error "Cancelled before modifying the existing user."
}

resolve_managed_user() {
  local configured_user=""
  local selection

  if ! configured_user="$(read_env_value "$VPSGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then
    configured_user=""
  fi
  PREVIOUS_MANAGED_USER="$configured_user"

  if [ -n "$REQUESTED_NEW_USER" ]; then
    validate_username "$REQUESTED_NEW_USER" || error "Invalid NEW_USER value: ${REQUESTED_NEW_USER}"
    NEW_USER="$REQUESTED_NEW_USER"
  elif [ -n "$configured_user" ]; then
    validate_username "$configured_user" || error "Configured NEW_USER is invalid. Repair ${VPSGUARD_CONFIG_FILE}."
    NEW_USER="$configured_user"
    info "检测到 VPSGuard 管理用户：${NEW_USER}"
    if [ -t 0 ]; then
      printf '1. 继续使用\n2. 更换管理用户\n3. 取消\n'
      read -r -p "请选择 [1]：" selection
      case "${selection:-1}" in
        1) ;;
        2) NEW_USER="$(prompt_for_username)" ;;
        3) error "Installation cancelled." ;;
        *) error "Invalid selection." ;;
      esac
    fi
  elif [ -t 0 ]; then
    NEW_USER="$(prompt_for_username)"
  else
    error "No managed username is configured. In non-interactive mode provide NEW_USER, for example: sudo -E env NEW_USER=myadmin bash install.sh"
  fi

  validate_username "$NEW_USER" || error "Resolved username is invalid."
  if [ -n "$PREVIOUS_MANAGED_USER" ] && [ "$PREVIOUS_MANAGED_USER" != "$NEW_USER" ]; then
    warn "Management is moving from ${PREVIOUS_MANAGED_USER} to ${NEW_USER}; the old user and its data will be preserved."
  fi
  validate_existing_user_account "$NEW_USER"
  if id "$NEW_USER" >/dev/null 2>&1; then
    confirm_existing_user "$NEW_USER"
  fi
}

validate_ssh_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

detect_current_ssh_port() {
  local detected connection_port

  connection_port="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk 'NF >= 4 {print $4}')"
  if validate_ssh_port "$connection_port"; then
    printf '%s\n' "$connection_port"
    return 0
  fi

  if ! detected="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"; then
    detected=""
  fi
  if ! validate_ssh_port "$detected"; then
    detected="22"
  fi
  printf '%s\n' "$detected"
}

prepare_sshd_runtime_directory() {
  ensure_directory "${VPSGUARD_RUN_ROOT}/sshd" 755
}

resolve_ssh_ports() {
  local configured_port configured_original

  if ! configured_port="$(read_env_value "$VPSGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)"; then
    configured_port=""
  fi
  if ! configured_original="$(read_env_value "$VPSGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)"; then
    configured_original=""
  fi
  ORIGINAL_SSH_PORT="$(detect_current_ssh_port)"

  if validate_ssh_port "$configured_original"; then
    ORIGINAL_SSH_PORT="$configured_original"
  fi

  if [ -n "$REQUESTED_SSH_PORT" ]; then
    validate_ssh_port "$REQUESTED_SSH_PORT" || error "SSH_PORT must be an integer from 1 to 65535."
    SSH_PORT="$REQUESTED_SSH_PORT"
  elif validate_ssh_port "$configured_port"; then
    SSH_PORT="$configured_port"
  else
    SSH_PORT="$ORIGINAL_SSH_PORT"
  fi

  info "SSH port plan: current/original=${ORIGINAL_SSH_PORT}, target=${SSH_PORT}"
}

upgrade_system() {
  info "Updating Ubuntu packages and installing VPSGuard dependencies..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
  DEBIAN_FRONTEND=noninteractive apt install -y sudo curl wget git vim nano unzip ufw fail2ban htop jq ca-certificates gnupg lsb-release net-tools iproute2 openssh-server
}

ensure_managed_user() {
  if id "$NEW_USER" >/dev/null 2>&1; then
    info "Reconciling existing user ${NEW_USER}."
  else
    [ -t 0 ] || error "Creating a new administrator requires a trusted interactive terminal so a sudo password can be set and validated. VPSGuard does not accept passwords through automation variables."
    info "Creating administrator user ${NEW_USER}."
    adduser --disabled-password --gecos "" "$NEW_USER"
  fi

  usermod -aG sudo "$NEW_USER"
  validate_existing_user_account "$NEW_USER"
}

managed_user_home() {
  getent passwd "$NEW_USER" | awk -F: '{print $6}'
}

check_root_ssh_key() {
  [ -s "$ROOT_AUTHORIZED_KEYS" ] || error "${ROOT_AUTHORIZED_KEYS} is missing or empty. Add a valid public key before running VPSGuard."
  awk 'NF && $1 !~ /^#/' "$ROOT_AUTHORIZED_KEYS" | grep -q . || error "No usable public-key entry was found in ${ROOT_AUTHORIZED_KEYS}."
  ssh-keygen -l -f "$ROOT_AUTHORIZED_KEYS" >/dev/null 2>&1 || error "${ROOT_AUTHORIZED_KEYS} does not contain a public key that ssh-keygen can parse."
}

configure_authorized_keys() {
  local user_home ssh_directory authorized_keys temporary_file

  check_root_ssh_key
  user_home="$(managed_user_home)"
  if [ -z "$user_home" ] || [ "$user_home" = "/" ]; then
    error "Could not resolve a safe home directory for ${NEW_USER}."
  fi
  ssh_directory="${user_home}/.ssh"
  authorized_keys="${ssh_directory}/authorized_keys"

  ensure_directory "$ssh_directory" 700
  temporary_file="$(mktemp "${authorized_keys}.tmp.XXXXXX")"
  if [ -f "$authorized_keys" ]; then
    awk 'NF && !seen[$0]++' "$authorized_keys" "$ROOT_AUTHORIZED_KEYS" > "$temporary_file"
  else
    awk 'NF && !seen[$0]++' "$ROOT_AUTHORIZED_KEYS" > "$temporary_file"
  fi
  [ -s "$temporary_file" ] || error "Refusing to install an empty authorized_keys file."
  chmod 600 "$temporary_file"
  chown "${NEW_USER}:${NEW_USER}" "$temporary_file"
  mv -f "$temporary_file" "$authorized_keys"
  chown -R "${NEW_USER}:${NEW_USER}" "$ssh_directory"
  chmod 700 "$ssh_directory"
  chmod 600 "$authorized_keys"
  info "Administrator authorized_keys reconciled without replacing existing keys."
}

sudoers_file_for_user() {
  printf '%s/90-vpsguard-%s\n' "$SUDOERS_DIR" "$NEW_USER"
}

user_in_sudo_group() {
  id -nG "$NEW_USER" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo
}

user_password_is_set() {
  local password_state

  if ! password_state="$(passwd -S "$NEW_USER" 2>/dev/null | awk '{print $2}')"; then
    password_state=""
  fi
  [ "$password_state" = "P" ]
}

sudo_policy_has_full_admin_from_text() {
  awk '
    /^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+ALL[[:space:]]*$/ {found=1}
    END {exit !found}
  '
}

ensure_sudo_password() {
  if user_password_is_set; then
    info "Administrator ${NEW_USER} has a password for standard sudo authentication."
    return 0
  fi

  [ -t 0 ] || error "Administrator ${NEW_USER} has no usable password. Set one with 'passwd ${NEW_USER}' from a trusted console, then rerun VPSGuard."
  warn "VPSGuard uses standard password-authenticated sudo. Set a strong password for ${NEW_USER}; it is not used for SSH login."
  passwd "$NEW_USER" || error "Could not set the sudo password for ${NEW_USER}."
  user_password_is_set || error "Password state for ${NEW_USER} is still locked or unavailable."
}

remove_vpsguard_passwordless_override() {
  local sudoers_file legacy_file

  sudoers_file="$(sudoers_file_for_user)"
  if [ -e "$sudoers_file" ]; then
    if head -n 1 "$sudoers_file" | grep -Fq 'Managed by VPSGuard'; then
      rm -f "$sudoers_file"
      info "Removed the legacy VPSGuard full passwordless sudo override."
    else
      error "Refusing to replace an unrecognized sudoers file: ${sudoers_file}"
    fi
  fi

  legacy_file="${SUDOERS_DIR}/90-${NEW_USER}"
  if [ -f "$legacy_file" ] && grep -Fxq "${NEW_USER} ALL=(ALL) NOPASSWD: ALL" "$legacy_file"; then
    rm -f "$legacy_file"
    info "Removed the recognized legacy passwordless sudo entry ${legacy_file}."
  fi
}

configure_sudo() {
  user_in_sudo_group || error "Administrator ${NEW_USER} is not a member of the sudo group."
  ensure_sudo_password
  remove_vpsguard_passwordless_override
  visudo -c >/dev/null || error "Global sudoers validation failed."
  info "Standard password-authenticated sudo policy is configured for ${NEW_USER}."
}

verify_sudo_configuration() {
  local sudoers_file policy_output

  sudoers_file="$(sudoers_file_for_user)"
  [ ! -e "$sudoers_file" ] || return 1
  user_in_sudo_group || return 1
  user_password_is_set || return 1
  visudo -c >/dev/null 2>&1 || return 1
  if ! policy_output="$(LC_ALL=C sudo -l -U "$NEW_USER" 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$policy_output" | sudo_policy_has_full_admin_from_text || return 1
  sudo -u "$NEW_USER" sudo -k >/dev/null 2>&1 || return 1
  if sudo -u "$NEW_USER" sudo -n true >/dev/null 2>&1; then
    return 1
  fi
}

confirm_sudo_password_authentication() {
  if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
    [ -t 0 ] || error "A terminal is required to validate the administrator's sudo password before SSH hardening."
    info "Enter the password for ${NEW_USER} once to validate 'sudo -i' authentication before SSH is changed."
  fi
  sudo -u "$NEW_USER" sudo -k >/dev/null 2>&1 || error "Could not invalidate the sudo credential cache for ${NEW_USER}."
  sudo -u "$NEW_USER" sudo -v || error "Password-authenticated sudo validation failed for ${NEW_USER}."
  sudo -u "$NEW_USER" sudo -k >/dev/null 2>&1 || error "Could not clear the sudo credential cache after validation."
}

ufw_rule_exists_from_text() {
  local port="$1"
  awk -v target="${port}/tcp" '$1 == target {found=1} END {exit !found}'
}

ufw_added_rule_exists_from_text() {
  local port="$1"
  awk -v target="${port}/tcp" '$1 == "ufw" && $2 == "allow" && $3 == target {found=1} END {exit !found}'
}

ufw_tcp_rule_exists() {
  local port="$1"
  if ufw status 2>/dev/null | ufw_rule_exists_from_text "$port"; then
    return 0
  fi
  ufw show added 2>/dev/null | ufw_added_rule_exists_from_text "$port"
}

ufw_is_active() {
  ufw status 2>/dev/null | awk 'NR == 1 && tolower($2) == "active" {found=1} END {exit !found}'
}

record_managed_rule() {
  local rule="$1"
  local temporary_file

  [ -f "$VPSGUARD_MANAGED_RULES" ] || atomic_write "$VPSGUARD_MANAGED_RULES" 600 "# UFW rules added by VPSGuard
"
  grep -Fxq "$rule" "$VPSGUARD_MANAGED_RULES" && return 0
  temporary_file="$(mktemp "${VPSGUARD_MANAGED_RULES}.tmp.XXXXXX")"
  awk 'NF && !seen[$0]++' "$VPSGUARD_MANAGED_RULES" > "$temporary_file"
  printf '%s\n' "$rule" >> "$temporary_file"
  chmod 600 "$temporary_file"
  if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$VPSGUARD_MANAGED_RULES"
}

remove_managed_rule_record() {
  local rule="$1"
  local temporary_file

  [ -f "$VPSGUARD_MANAGED_RULES" ] || return 0
  temporary_file="$(mktemp "${VPSGUARD_MANAGED_RULES}.tmp.XXXXXX")"
  awk -v unwanted="$rule" '$0 != unwanted' "$VPSGUARD_MANAGED_RULES" > "$temporary_file"
  chmod 600 "$temporary_file"
  if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$VPSGUARD_MANAGED_RULES"
}

ensure_ufw_tcp_rule() {
  local port="$1"

  if ufw_tcp_rule_exists "$port"; then
    info "UFW already has an exact ${port}/tcp rule."
    return 0
  fi

  ufw allow "${port}/tcp"
  ufw_tcp_rule_exists "$port" || error "UFW did not expose the newly added exact ${port}/tcp rule."
  record_managed_rule "${port}/tcp"
  info "Added and recorded UFW rule ${port}/tcp."
}

configure_ufw_before_ssh() {
  local active="false"

  if ufw_is_active; then
    active="true"
  fi

  ensure_ufw_tcp_rule "$SSH_PORT"
  if [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    ensure_ufw_tcp_rule "$ORIGINAL_SSH_PORT"
  fi

  if [ "$active" != "true" ]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
  fi
  ufw_is_active || error "UFW is not active after configuration."
}

write_vpsguard_sshd_config() {
  local keep_old_port="${1:-false}"
  local port_lines content

  assert_managed_or_absent "$VPSGUARD_SSHD_CONFIG"
  port_lines="Port ${SSH_PORT}"
  if [ "$keep_old_port" = "true" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    port_lines="${port_lines}
Port ${ORIGINAL_SSH_PORT}"
  fi

  content="# Managed by VPSGuard ${VPSGUARD_VERSION}. Do not edit; change ${VPSGUARD_CONFIG_FILE} and rerun.
${port_lines}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
"
  atomic_write "$VPSGUARD_SSHD_CONFIG" 600 "$content"
}

ensure_vpsguard_sshd_include_first() {
  local begin_count end_count begin_line end_line existing_content content mode

  [ -f "$SSHD_CONFIG" ] || error "OpenSSH server config is missing: ${SSHD_CONFIG}"
  if ! begin_count="$(grep -Fxc "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"; then begin_count=0; fi
  if ! end_count="$(grep -Fxc "$SSHD_INCLUDE_END" "$SSHD_CONFIG")"; then end_count=0; fi
  if { [ "$begin_count" -ne 0 ] || [ "$end_count" -ne 0 ]; } \
    && { [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; }; then
    error "Refusing to modify malformed VPSGuard include markers in ${SSHD_CONFIG}."
  fi
  if [ "$begin_count" -eq 1 ]; then
    begin_line="$(grep -Fn "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG" | cut -d: -f1)"
    end_line="$(grep -Fn "$SSHD_INCLUDE_END" "$SSHD_CONFIG" | cut -d: -f1)"
    [ "$begin_line" -lt "$end_line" ] || error "VPSGuard include markers are out of order in ${SSHD_CONFIG}."
  fi

  existing_content="$(awk -v begin="$SSHD_INCLUDE_BEGIN" -v end="$SSHD_INCLUDE_END" '
    $0 == begin {inside=1; next}
    $0 == end {inside=0; next}
    !inside {print}
  ' "$SSHD_CONFIG")"
  content="${SSHD_INCLUDE_BEGIN}
Include ${VPSGUARD_SSHD_CONFIG}
${SSHD_INCLUDE_END}
${existing_content}
"
  if ! mode="$(stat -c '%a' "$SSHD_CONFIG" 2>/dev/null)"; then mode=644; fi
  atomic_write "$SSHD_CONFIG" "$mode" "$content"
}

write_vpsguard_ssh_socket_override() {
  local keep_old_port="${1:-false}"
  local listen_lines content

  assert_managed_or_absent "$VPSGUARD_SSH_SOCKET_OVERRIDE"
  listen_lines="ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}"
  if [ "$keep_old_port" = "true" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    listen_lines="${listen_lines}
ListenStream=0.0.0.0:${ORIGINAL_SSH_PORT}
ListenStream=[::]:${ORIGINAL_SSH_PORT}"
  fi
  content="# Managed by VPSGuard ${VPSGUARD_VERSION}
[Socket]
ListenStream=
${listen_lines}
"
  atomic_write "$VPSGUARD_SSH_SOCKET_OVERRIDE" 644 "$content"
}

write_vpsguard_ssh_runtime_policy() {
  local keep_old_port="${1:-false}"

  write_vpsguard_sshd_config "$keep_old_port"
  ensure_vpsguard_sshd_include_first
  detect_ssh_runtime_mode
  if [ "$SSH_RUNTIME_MODE" = "socket" ]; then
    write_vpsguard_ssh_socket_override "$keep_old_port"
  elif [ -f "$VPSGUARD_SSH_SOCKET_OVERRIDE" ] && head -n 1 "$VPSGUARD_SSH_SOCKET_OVERRIDE" | grep -Fq 'Managed by VPSGuard'; then
    rm -f "$VPSGUARD_SSH_SOCKET_OVERRIDE"
  fi
}

effective_sshd_value_from_text() {
  local key="$1"
  awk -v wanted="$key" '$1 == wanted {print $2; exit}'
}

effective_sshd_has_port_from_text() {
  local port="$1"
  awk -v wanted="$port" '$1 == "port" && $2 == wanted {found=1} END {exit !found}'
}

verify_effective_sshd_config() {
  local output permit_root password_auth pubkey_auth failed=0 client_address host_context

  sshd -t || return 1
  if [ -n "${SSHD_T_OUTPUT_OVERRIDE:-}" ]; then
    output="$SSHD_T_OUTPUT_OVERRIDE"
  else
    client_address="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk 'NF >= 1 {print $1}')"
    host_context="$(hostname -f 2>/dev/null || hostname)"
    if [ -n "$client_address" ] && output="$(sshd -T -C "user=${NEW_USER},host=${host_context},addr=${client_address}" 2>/dev/null)"; then
      :
    else
      output="$(sshd -T 2>/dev/null)"
    fi
  fi
  printf '%s\n' "$output" | effective_sshd_has_port_from_text "$SSH_PORT" || { warn "Effective SSH port does not include ${SSH_PORT}."; failed=1; }
  permit_root="$(printf '%s\n' "$output" | effective_sshd_value_from_text permitrootlogin)"
  password_auth="$(printf '%s\n' "$output" | effective_sshd_value_from_text passwordauthentication)"
  pubkey_auth="$(printf '%s\n' "$output" | effective_sshd_value_from_text pubkeyauthentication)"
  [ "$permit_root" = "no" ] || { warn "Effective PermitRootLogin is ${permit_root:-missing}, expected no."; failed=1; }
  [ "$password_auth" = "no" ] || { warn "Effective PasswordAuthentication is ${password_auth:-missing}, expected no."; failed=1; }
  [ "$pubkey_auth" = "yes" ] || { warn "Effective PubkeyAuthentication is ${pubkey_auth:-missing}, expected yes."; failed=1; }
  [ "$failed" -eq 0 ]
}

unit_exists() {
  local unit="$1"
  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk -v wanted="$unit" '$1 == wanted {found=1} END {exit !found}'
}

detect_ssh_runtime_mode() {
  SSH_RUNTIME_MODE="service"
  SSH_SERVICE_UNIT="ssh.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    SSH_RUNTIME_MODE="legacy"
    if command -v service >/dev/null 2>&1 && service ssh status >/dev/null 2>&1; then
      SSH_SERVICE_UNIT="ssh"
    else
      SSH_SERVICE_UNIT="sshd"
    fi
    return 0
  fi

  if unit_exists sshd.service && ! unit_exists ssh.service; then
    SSH_SERVICE_UNIT="sshd.service"
  fi

  if unit_exists ssh.socket && { systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; }; then
    SSH_RUNTIME_MODE="socket"
  fi
}

apply_ssh_runtime() {
  detect_ssh_runtime_mode

  case "$SSH_RUNTIME_MODE" in
    socket)
      systemctl daemon-reload
      systemctl restart ssh.socket
      if systemctl is-active --quiet "$SSH_SERVICE_UNIT"; then
        systemctl reload "$SSH_SERVICE_UNIT" || systemctl restart "$SSH_SERVICE_UNIT"
      fi
      systemctl is-active --quiet ssh.socket || return 1
      ;;
    service)
      if systemctl is-active --quiet "$SSH_SERVICE_UNIT"; then
        systemctl reload "$SSH_SERVICE_UNIT" || systemctl restart "$SSH_SERVICE_UNIT"
      else
        systemctl start "$SSH_SERVICE_UNIT"
      fi
      systemctl is-active --quiet "$SSH_SERVICE_UNIT" || return 1
      ;;
    legacy)
      service "$SSH_SERVICE_UNIT" reload || service "$SSH_SERVICE_UNIT" restart
      ;;
    *) return 1 ;;
  esac
}

ssh_listener_present_from_text() {
  local port="$1"
  awk -v wanted="$port" '
    $1 == "LISTEN" {
      address=$4
      sub(/^.*:/, "", address)
      if (address == wanted && ($0 ~ /sshd/ || $0 ~ /systemd/)) found=1
    }
    END {exit !found}
  '
}

verify_ssh_listener() {
  local port="$1"
  local output
  output="${SS_LISTEN_OUTPUT_OVERRIDE:-$(ss -ltnpH 2>/dev/null)}"
  printf '%s\n' "$output" | ssh_listener_present_from_text "$port"
}

configure_ssh_safely() {
  local keep_old_port="false"
  local answer=""

  if [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    keep_old_port="true"
  fi

  write_vpsguard_ssh_runtime_policy "$keep_old_port"
  verify_effective_sshd_config || error "Effective sshd configuration does not match the VPSGuard policy. SSH was not restarted."
  apply_ssh_runtime || error "Failed to apply SSH configuration safely. Keep the current root session open."
  verify_ssh_listener "$SSH_PORT" || error "Target SSH port ${SSH_PORT} is not listening through sshd/systemd. Old UFW access was preserved."
  if [ "$keep_old_port" = "true" ]; then
    verify_ssh_listener "$ORIGINAL_SSH_PORT" || error "Old SSH port ${ORIGINAL_SSH_PORT} was not preserved during staging. Keep the current session open and inspect SSH manually."
  fi
  ufw_tcp_rule_exists "$SSH_PORT" || error "Target SSH port ${SSH_PORT}/tcp is not allowed by UFW."

  if [ "$ORIGINAL_SSH_PORT" = "$SSH_PORT" ]; then
    rm -f "$VPSGUARD_PENDING_PORT_MARKER"
    return 0
  fi

  atomic_write "$VPSGUARD_PENDING_PORT_MARKER" 600 "target=${SSH_PORT}
old=${ORIGINAL_SSH_PORT}
"
  warn "New SSH port ${SSH_PORT} is listening locally. Old port ${ORIGINAL_SSH_PORT} remains listening and allowed until remote login is confirmed."
  printf '请在第二个终端测试：ssh -p %s %s@SERVER_IP\n' "$SSH_PORT" "$NEW_USER"

  if [ -t 0 ]; then
    read -r -p "确认第二终端登录和 sudo 正常后输入 YES；其他输入保留旧端口：" answer
  fi
  if [ "$answer" != "YES" ]; then
    INSTALL_STATUS="pending-port-finalization"
    return 0
  fi

  write_vpsguard_ssh_runtime_policy false
  verify_effective_sshd_config || error "Final SSH configuration validation failed; old UFW rule remains."
  apply_ssh_runtime || error "Could not finalize the SSH runtime; old UFW rule remains."
  verify_ssh_listener "$SSH_PORT" || error "Target SSH listener disappeared during finalization; old UFW rule remains."

  if grep -Fxq "${ORIGINAL_SSH_PORT}/tcp" "$VPSGUARD_MANAGED_RULES" 2>/dev/null; then
    ufw --force delete allow "${ORIGINAL_SSH_PORT}/tcp"
    remove_managed_rule_record "${ORIGINAL_SSH_PORT}/tcp"
  else
    warn "Old UFW rule ${ORIGINAL_SSH_PORT}/tcp predates VPSGuard and was preserved."
  fi
  rm -f "$VPSGUARD_PENDING_PORT_MARKER"
}

wait_for_fail2ban_sshd_jail() {
  local attempt

  for ((attempt = 1; attempt <= FAIL2BAN_READY_ATTEMPTS; attempt++)); do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -lt "$FAIL2BAN_READY_ATTEMPTS" ]; then
      sleep 1
    fi
  done
  return 1
}

configure_fail2ban() {
  local content protected_ports
  assert_managed_or_absent "$FAIL2BAN_JAIL"
  protected_ports="$SSH_PORT"
  if [ -f "$VPSGUARD_PENDING_PORT_MARKER" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    protected_ports="${SSH_PORT},${ORIGINAL_SSH_PORT}"
  fi
  content="# Managed by VPSGuard ${VPSGUARD_VERSION}
[sshd]
enabled = true
port = ${protected_ports}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
"
  atomic_write "$FAIL2BAN_JAIL" 644 "$content"
  fail2ban-client -t >/dev/null 2>&1 || error "The fail2ban configuration test failed."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable fail2ban.service
    systemctl restart fail2ban.service
    systemctl is-active --quiet fail2ban.service || error "fail2ban did not become active."
  else
    service fail2ban restart
  fi
  wait_for_fail2ban_sshd_jail || error "The fail2ban sshd jail did not become ready."
}

available_congestion_controls() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || return 0
}

classify_bbr_state() {
  local available="$1"
  local current="$2"
  local qdisc="$3"
  local apply_failed="${4:-false}"

  if [ "$current" = "bbr" ] && [ "$qdisc" = "fq" ]; then
    printf 'already-enabled\n'
  elif ! printf ' %s ' "$available" | grep -Fq ' bbr '; then
    printf 'unsupported\n'
  elif [ "$apply_failed" = "true" ]; then
    printf 'failed\n'
  else
    printf 'enabled\n'
  fi
}

write_bbr_files() {
  local module_persistence="${BBR_MODULE_PERSISTENCE_REQUIRED:-auto}"

  assert_managed_or_absent "$BBR_SYSCTL_FILE"
  atomic_write "$BBR_SYSCTL_FILE" 644 "# Managed by VPSGuard ${VPSGUARD_VERSION}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
"

  if [ "$module_persistence" = "auto" ]; then
    if lsmod 2>/dev/null | awk '$1 == "tcp_bbr" {found=1} END {exit !found}'; then
      module_persistence="true"
    else
      module_persistence="false"
    fi
  fi
  if [ "$module_persistence" = "true" ] || [ "$module_persistence" = "1" ]; then
    assert_managed_or_absent "$BBR_MODULES_FILE"
    atomic_write "$BBR_MODULES_FILE" 644 "# Managed by VPSGuard ${VPSGUARD_VERSION}
tcp_bbr
"
  elif [ -f "$BBR_MODULES_FILE" ] && head -n 1 "$BBR_MODULES_FILE" | grep -Fq 'Managed by VPSGuard'; then
    rm -f "$BBR_MODULES_FILE"
  fi
}

migrate_legacy_bbr_file() {
  local legacy_file="${VPSGUARD_ETC_ROOT}/sysctl.d/99-bbr.conf"
  local normalized

  [ -f "$legacy_file" ] || return 0
  normalized="$(awk 'NF && $1 !~ /^#/ {gsub(/[[:space:]]/, ""); print}' "$legacy_file")"
  if [ "$normalized" = $'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr' ]; then
    rm -f "$legacy_file"
    info "Removed the exact legacy VPSGuard BBR file after migrating to ${BBR_SYSCTL_FILE}."
  else
    warn "Preserved unrecognized legacy BBR file: ${legacy_file}"
  fi
}

enable_bbr() {
  local available current qdisc apply_failed="false" initial_status

  available="$(available_congestion_controls)"
  if ! current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current=""; fi
  if ! qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then qdisc=""; fi
  initial_status="$(classify_bbr_state "$available" "$current" "$qdisc")"
  if [ "$initial_status" = "already-enabled" ]; then
    write_bbr_files
    migrate_legacy_bbr_file
    BBR_STATUS="already-enabled"
    return 0
  fi

  if ! printf ' %s ' "$available" | grep -Fq ' bbr '; then
    if command -v modprobe >/dev/null 2>&1; then
      if ! modprobe tcp_bbr >/dev/null 2>&1; then
        warn "modprobe tcp_bbr failed; checking whether BBR is built into or otherwise exposed by the kernel."
      fi
    fi
    available="$(available_congestion_controls)"
  fi
  if ! printf ' %s ' "$available" | grep -Fq ' bbr '; then
    BBR_STATUS="unsupported"
    warn "BBR is unavailable in this kernel/container; continuing without kernel replacement."
    return 0
  fi

  write_bbr_files
  migrate_legacy_bbr_file
  sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || apply_failed="true"
  if ! current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current=""; fi
  if ! qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then qdisc=""; fi
  BBR_STATUS="$(classify_bbr_state "$available" "$current" "$qdisc" "$apply_failed")"

  case "$BBR_STATUS" in
    enabled|already-enabled) info "BBR status: ${BBR_STATUS} (bbr + fq)." ;;
    failed) warn "BBR is supported but could not be applied; core SSH installation will continue." ;;
    unsupported) warn "BBR is unsupported; core SSH installation will continue." ;;
  esac
}

verify_authorized_keys() {
  local user_home ssh_directory authorized_keys owner ssh_mode key_mode

  user_home="$(managed_user_home)"
  ssh_directory="${user_home}/.ssh"
  authorized_keys="${ssh_directory}/authorized_keys"
  [ -s "$authorized_keys" ] || return 1
  if ! owner="$(stat -c '%U:%G' "$authorized_keys" 2>/dev/null)"; then owner=""; fi
  if ! ssh_mode="$(stat -c '%a' "$ssh_directory" 2>/dev/null)"; then ssh_mode=""; fi
  if ! key_mode="$(stat -c '%a' "$authorized_keys" 2>/dev/null)"; then key_mode=""; fi
  [ "$owner" = "${NEW_USER}:${NEW_USER}" ] && [ "$ssh_mode" = "700" ] && [ "$key_mode" = "600" ]
}

verify_ssh_runtime_healthy() {
  detect_ssh_runtime_mode
  case "$SSH_RUNTIME_MODE" in
    socket) systemctl is-active --quiet ssh.socket ;;
    service) systemctl is-active --quiet "$SSH_SERVICE_UNIT" ;;
    legacy) service "$SSH_SERVICE_UNIT" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

verify_config_permissions() {
  local owner mode
  if ! owner="$(stat -c '%U:%G' "$VPSGUARD_CONFIG_FILE" 2>/dev/null)"; then owner=""; fi
  if ! mode="$(stat -c '%a' "$VPSGUARD_CONFIG_FILE" 2>/dev/null)"; then mode=""; fi
  [ "$owner" = "root:root" ] && [ "$mode" = "600" ]
}

run_final_acceptance() {
  local failures=0 warnings=0 current_cc current_qdisc

  id "$NEW_USER" >/dev/null 2>&1 || { warn "Acceptance: managed user missing."; failures=$((failures + 1)); }
  validate_existing_user_account "$NEW_USER"
  verify_authorized_keys || { warn "Acceptance: authorized_keys ownership or permissions are invalid."; failures=$((failures + 1)); }
  verify_sudo_configuration || { warn "Acceptance: sudo validation failed."; failures=$((failures + 1)); }
  verify_effective_sshd_config || { warn "Acceptance: effective SSH policy mismatch."; failures=$((failures + 1)); }
  verify_ssh_runtime_healthy || { warn "Acceptance: SSH service/socket runtime is unhealthy."; failures=$((failures + 1)); }
  verify_ssh_listener "$SSH_PORT" || { warn "Acceptance: target SSH listener missing."; failures=$((failures + 1)); }
  ufw_is_active || { warn "Acceptance: UFW is inactive."; failures=$((failures + 1)); }
  ufw_tcp_rule_exists "$SSH_PORT" || { warn "Acceptance: target UFW rule missing."; failures=$((failures + 1)); }
  verify_config_permissions || { warn "Acceptance: VPSGuard config ownership or mode is invalid."; failures=$((failures + 1)); }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet fail2ban.service || { warn "Acceptance: fail2ban service is inactive."; failures=$((failures + 1)); }
  fi
  fail2ban-client status sshd >/dev/null 2>&1 || { warn "Acceptance: fail2ban sshd jail unavailable."; failures=$((failures + 1)); }

  if ! current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current_cc=""; fi
  if ! current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then current_qdisc=""; fi
  if [ "$current_cc" != "bbr" ] || [ "$current_qdisc" != "fq" ]; then
    warnings=$((warnings + 1))
  fi

  [ "$failures" -eq 0 ] || return 1
  if [ "$INSTALL_STATUS" = "pending-port-finalization" ]; then
    :
  elif [ "$warnings" -gt 0 ]; then
    INSTALL_STATUS="success-with-warnings"
  else
    INSTALL_STATUS="success"
  fi
  if [ -n "$PREVIOUS_MANAGED_USER" ] && [ "$PREVIOUS_MANAGED_USER" != "$NEW_USER" ]; then
    warn "Previous managed user ${PREVIOUS_MANAGED_USER} still exists and was not deleted. Review its access manually."
  fi
  write_config_env
  atomic_write "$VPSGUARD_INSTALLED_MARKER" 600 "${INSTALL_STATUS}
"
}

print_final_summary() {
  local server_ip
  server_ip="$(curl -4 --max-time 3 -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

  printf '\n%bVPSGuard %s acceptance completed%b\n' "$BOLD" "$VPSGUARD_VERSION" "$NC"
  printf 'Install status: %s\n' "$INSTALL_STATUS"
  printf 'Managed user: %s\n' "$NEW_USER"
  printf 'Target SSH port: %s\n' "$SSH_PORT"
  printf 'SSH runtime mode: %s\n' "$SSH_RUNTIME_MODE"
  printf 'BBR status: %s\n' "$BBR_STATUS"
  printf 'Test from a second terminal: ssh -p %s %s@%s\n' "$SSH_PORT" "$NEW_USER" "${server_ip:-SERVER_IP}"
  printf '%bDo not close the current session until remote login and sudo are verified.%b\n' "$YELLOW" "$NC"
  if [ "$INSTALL_STATUS" = "pending-port-finalization" ]; then
    warn "Old SSH port ${ORIGINAL_SSH_PORT} is intentionally retained. Rerun VPSGuard after remote validation to finalize."
  fi
}

remove_legacy_phase_markers() {
  rm -f "${VPSGUARD_STATE_DIR}/.ssh_done" "${VPSGUARD_STATE_DIR}/.sudo_done" "${VPSGUARD_STATE_DIR}/.ufw_done"
}

main() {
  require_root
  check_ubuntu_lts
  ensure_directory "$VPSGUARD_STATE_DIR" 700
  prepare_sshd_runtime_directory
  resolve_managed_user
  resolve_ssh_ports
  INSTALL_STATUS="failed"
  write_config_env
  record_preinstall_state
  upgrade_system
  # An OpenSSH package upgrade can remove /run/sshd while restarting the
  # socket-activated service. Recreate it before any post-upgrade sshd check.
  prepare_sshd_runtime_directory

  ensure_managed_user
  configure_authorized_keys
  configure_sudo
  verify_sudo_configuration || error "Sudo validation failed. SSH hardening was not started."
  confirm_sudo_password_authentication

  configure_ufw_before_ssh
  configure_ssh_safely
  configure_fail2ban
  enable_bbr

  run_final_acceptance || error "Final acceptance failed. The installed marker was not written; keep the current SSH session open."
  remove_legacy_phase_markers
  print_final_summary
}

if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
