#!/usr/bin/env bash
set -euo pipefail

# Hguard v0.4.0
# Ubuntu LTS initialization and SSH hardening with lockout-safe convergence.

HGUARD_VERSION="0.4.0"
HGUARD_TEST_MODE="${HGUARD_TEST_MODE:-0}"
# Set by status/verify/update/uninstall when they source this file to reuse
# its constants and functions without running the installer's own main().
# Distinct from HGUARD_TEST_MODE, which also flips several functions'
# internal behavior to a sandboxed fake (e.g. apply_conntrack_runtime_values)
# - lib mode must get the real production behavior of every function.
HGUARD_LIB_MODE="${HGUARD_LIB_MODE:-0}"
HGUARD_PROC_ROOT="${HGUARD_PROC_ROOT:-/proc}"
HGUARD_PROC_SYS_ROOT="${HGUARD_PROC_SYS_ROOT:-${HGUARD_PROC_ROOT}/sys}"
HGUARD_SYS_MODULE_ROOT="${HGUARD_SYS_MODULE_ROOT:-/sys/module}"
HGUARD_ETC_ROOT="${HGUARD_ETC_ROOT:-/etc}"
HGUARD_RUN_ROOT="${HGUARD_RUN_ROOT:-/run}"
HGUARD_LOG_FILE="${HGUARD_LOG_FILE:-/var/log/hguard.log}"
HGUARD_STATE_DIR="${HGUARD_STATE_DIR:-${HGUARD_ETC_ROOT}/hguard}"
HGUARD_CONFIG_FILE="${HGUARD_CONFIG_FILE:-${HGUARD_STATE_DIR}/config.env}"
HGUARD_STATE_FILE="${HGUARD_STATE_FILE:-${HGUARD_STATE_DIR}/state.env}"
HGUARD_MANAGED_RULES="${HGUARD_MANAGED_RULES:-${HGUARD_STATE_DIR}/managed-rules}"
HGUARD_INSTALLED_MARKER="${HGUARD_INSTALLED_MARKER:-${HGUARD_STATE_DIR}/.installed}"
HGUARD_PENDING_PORT_MARKER="${HGUARD_PENDING_PORT_MARKER:-${HGUARD_STATE_DIR}/.pending-port-finalization}"
HGUARD_APT_HOOK_STATE_FILE="${HGUARD_APT_HOOK_STATE_FILE:-${HGUARD_STATE_DIR}/apt-hook-verify.env}"
HGUARD_APT_HOOK_VERSIONS_FILE="${HGUARD_APT_HOOK_VERSIONS_FILE:-${HGUARD_STATE_DIR}/apt-hook-versions.env}"

SSHD_CONFIG="${SSHD_CONFIG:-${HGUARD_ETC_ROOT}/ssh/sshd_config}"
SSHD_CONFIG_DIR="${SSHD_CONFIG_DIR:-${HGUARD_ETC_ROOT}/ssh/sshd_config.d}"
HGUARD_SSHD_CONFIG="${HGUARD_SSHD_CONFIG:-${SSHD_CONFIG_DIR}/00-hguard.conf}"
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-${HGUARD_ETC_ROOT}/systemd/system}"
HGUARD_SSH_SOCKET_OVERRIDE="${HGUARD_SSH_SOCKET_OVERRIDE:-${SYSTEMD_SYSTEM_DIR}/ssh.socket.d/00-hguard.conf}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local}"
SUDOERS_DIR="${SUDOERS_DIR:-${HGUARD_ETC_ROOT}/sudoers.d}"
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-bbr.conf}"
BBR_MODULES_FILE="${BBR_MODULES_FILE:-${HGUARD_ETC_ROOT}/modules-load.d/hguard-bbr.conf}"
CONNTRACK_SYSCTL_FILE="${CONNTRACK_SYSCTL_FILE:-${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-conntrack.conf}"
CONNTRACK_MODPROBE_FILE="${CONNTRACK_MODPROBE_FILE:-${HGUARD_ETC_ROOT}/modprobe.d/hguard-nf-conntrack.conf}"
CONNTRACK_MODULES_FILE="${CONNTRACK_MODULES_FILE:-${HGUARD_ETC_ROOT}/modules-load.d/hguard-conntrack.conf}"
CONNTRACK_HELPER_FILE="${CONNTRACK_HELPER_FILE:-${HGUARD_STATE_DIR}/apply-conntrack-profile.sh}"
CONNTRACK_SERVICE_NAME="${CONNTRACK_SERVICE_NAME:-hguard-conntrack.service}"
CONNTRACK_SERVICE_FILE="${CONNTRACK_SERVICE_FILE:-${SYSTEMD_SYSTEM_DIR}/${CONNTRACK_SERVICE_NAME}}"
ROOT_AUTHORIZED_KEYS="${ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
HGUARD_BIN_DIR="${HGUARD_BIN_DIR:-/usr/local/sbin}"
HGUARD_LIB_DIR="${HGUARD_LIB_DIR:-/usr/local/lib/hguard}"
HGUARD_CLI_PATH="${HGUARD_CLI_PATH:-${HGUARD_BIN_DIR}/hguard}"
APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt/apt.conf.d}"
HGUARD_APT_HOOK_FILE="${HGUARD_APT_HOOK_FILE:-${APT_CONF_DIR}/99-hguard-verify}"
HGUARD_APT_HOOK_SCRIPT="${HGUARD_APT_HOOK_SCRIPT:-${HGUARD_LIB_DIR}/apt-hook.sh}"
# Deliberately NOT overridable via environment (no ${VAR:-default} pattern),
# unlike every other constant in this file: this one controls where root
# fetches code that then gets installed executable and later run as root
# via the hguard dispatcher. An env-var override here would let anything
# that can set environment variables for the install process (e.g. sudo -E
# with an inherited environment) redirect root into fetching and installing
# attacker-controlled code. Matches install.sh's CORE_URL, which is
# hardcoded for the same reason.
HGUARD_RAW_BASE_URL="https://raw.githubusercontent.com/hcloudlab/Hguard"

# VPSGuard-era (pre-rename) paths, only ever read/removed by
# migrate_from_vpsguard() and never written to - current code always
# writes the HGUARD_* equivalents above.
VPSGUARD_LEGACY_STATE_DIR="${VPSGUARD_LEGACY_STATE_DIR:-${HGUARD_ETC_ROOT}/vpsguard}"
VPSGUARD_LEGACY_SSHD_CONFIG="${SSHD_CONFIG_DIR}/00-vpsguard.conf"
VPSGUARD_LEGACY_SSH_SOCKET_OVERRIDE="${SYSTEMD_SYSTEM_DIR}/ssh.socket.d/00-vpsguard.conf"
VPSGUARD_LEGACY_FAIL2BAN_JAIL="${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local"
VPSGUARD_LEGACY_BBR_SYSCTL_FILE="${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf"
VPSGUARD_LEGACY_BBR_MODULES_FILE="${HGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf"
VPSGUARD_LEGACY_CONNTRACK_SYSCTL_FILE="${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-conntrack.conf"
VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE="${HGUARD_ETC_ROOT}/modprobe.d/vpsguard-nf-conntrack.conf"
VPSGUARD_LEGACY_CONNTRACK_MODULES_FILE="${HGUARD_ETC_ROOT}/modules-load.d/vpsguard-conntrack.conf"
VPSGUARD_LEGACY_CONNTRACK_HELPER_FILE="${VPSGUARD_LEGACY_STATE_DIR}/apply-conntrack-profile.sh"
VPSGUARD_LEGACY_CONNTRACK_SERVICE_NAME="vpsguard-conntrack.service"
VPSGUARD_LEGACY_CONNTRACK_SERVICE_FILE="${SYSTEMD_SYSTEM_DIR}/${VPSGUARD_LEGACY_CONNTRACK_SERVICE_NAME}"
VPSGUARD_LEGACY_SSHD_INCLUDE_BEGIN="# BEGIN VPSGuard managed include"
VPSGUARD_LEGACY_SSHD_INCLUDE_END="# END VPSGuard managed include"
VPSGUARD_MIGRATED_MARKER_FILE="${VPSGUARD_LEGACY_STATE_DIR}/MIGRATED-TO-HGUARD"

OPTIMIZE_CONNTRACK="false"
REQUESTED_NEW_USER="${NEW_USER:-}"
REQUESTED_SSH_PORT="${SSH_PORT:-}"
REQUESTED_ALLOW_PORTS="${ALLOW_PORTS:-}"
ALLOW_SSH_ONLY="false"
NEW_USER=""
PREVIOUS_MANAGED_USER=""
SUDO_MODE=""
PREVIOUS_SUDO_MODE=""
SSH_PORT=""
ORIGINAL_SSH_PORT=""
PORT_MIGRATION_REQUIRED="false"
ATOMIC_WRITE_CHANGED="false"
INSTALL_STATUS="failed"
BBR_STATUS="unsupported"
SSH_RUNTIME_MODE="unknown"
SSH_SERVICE_UNIT=""
INSTALLER_IP=""
FAIL2BAN_READY_ATTEMPTS=15
SSHD_INCLUDE_BEGIN="# BEGIN Hguard managed include"
SSHD_INCLUDE_END="# END Hguard managed include"
MANAGED_MARKER="Managed by Hguard"
# The VPSGuard-era marker (pre-rename). Only migrate_from_vpsguard() and the
# dual-recognition helpers below should ever look for this - everything
# that writes or validates a *current* Hguard-managed file uses
# MANAGED_MARKER alone.
LEGACY_MANAGED_MARKER="Managed by VPSGuard"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
NC="\033[0m"

log_plain() {
  local level="$1"
  local message="$2"

  if [ "$HGUARD_TEST_MODE" = "1" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$HGUARD_LOG_FILE")"
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$message" >> "$HGUARD_LOG_FILE"
  chmod 600 "$HGUARD_LOG_FILE"
}

info() {
  printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"
  log_plain INFO "$1"
}

ok() {
  printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$1"
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
  # Re-check for a symlink immediately before chmod/chown, not just before
  # mkdir -p: mkdir -p is a no-op if the path already exists in any form,
  # and chmod/chown follow a symlink by default, so a path swapped to a
  # symlink between an earlier check and here would make these root-owned
  # operations run against an attacker-chosen target instead.
  [ ! -L "$path" ] || error "${path} is a symlink; refusing to follow it."
  chmod "$mode" "$path"
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$path"
  fi
}

atomic_write() {
  local path="$1"
  local mode="$2"
  local content="$3"
  local directory
  local temporary_file

  ATOMIC_WRITE_CHANGED="false"
  if [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$(printf '%s' "$content")" ]; then
    return 0
  fi

  directory="$(dirname "$path")"
  if [ ! -d "$directory" ]; then
    mkdir -p "$directory"
    chmod 755 "$directory"
    if [ "$HGUARD_TEST_MODE" != "1" ]; then
      chown root:root "$directory"
    fi
  fi
  temporary_file="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$content" > "$temporary_file"
  chmod "$mode" "$temporary_file"
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$path"
  ATOMIC_WRITE_CHANGED="true"
}

assert_managed_or_absent() {
  local path="$1"
  if [ -e "$path" ] && ! head -n 2 "$path" | grep -Fq "$MANAGED_MARKER"; then
    error "Refusing to overwrite an unrecognized existing file: ${path}"
  fi
}

parse_args() {
  local argument

  for argument in "$@"; do
    case "$argument" in
      --optimize-conntrack)
        OPTIMIZE_CONNTRACK="true"
        ;;
      --ssh-only)
        ALLOW_SSH_ONLY="true"
        ;;
      -h|--help)
        printf 'Usage: sudo bash install.sh [--optimize-conntrack] [--ssh-only]\n'
        exit 0
        ;;
      *)
        error "Unknown option: ${argument}"
        ;;
    esac
  done
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
  local sudo_mode="${1-$SUDO_MODE}"
  local install_status="${2:-$INSTALL_STATUS}"
  local content sudo_mode_line=""

  if validate_sudo_mode "$sudo_mode"; then
    sudo_mode_line="SUDO_MODE='${sudo_mode}'
"
  fi

  content="# Managed by Hguard ${HGUARD_VERSION}; values are validated before use.
NEW_USER='${NEW_USER}'
${sudo_mode_line}SSH_PORT='${SSH_PORT}'
ORIGINAL_SSH_PORT='${ORIGINAL_SSH_PORT}'
INSTALL_STATUS='${install_status}'
"
  atomic_write "$HGUARD_CONFIG_FILE" 600 "$content"
}

write_pending_config_env() {
  local effective_mode=""

  if validate_sudo_mode "$PREVIOUS_SUDO_MODE"; then
    effective_mode="$PREVIOUS_SUDO_MODE"
  fi
  write_config_env "$effective_mode" "$INSTALL_STATUS"
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
  local conntrack_sysctl_preexisting conntrack_modprobe_preexisting conntrack_modules_preexisting
  local conntrack_helper_preexisting conntrack_service_preexisting
  local content

  if [ -f "$HGUARD_STATE_FILE" ]; then
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

  sshd_dropin_preexisting="$(boolean_command_state test -e "$HGUARD_SSHD_CONFIG")"
  sshd_include_preexisting="$(boolean_command_state grep -Fqx "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"
  ssh_socket_override_preexisting="$(boolean_command_state test -e "$HGUARD_SSH_SOCKET_OVERRIDE")"
  fail2ban_jail_preexisting="$(boolean_command_state test -e "$FAIL2BAN_JAIL")"
  bbr_sysctl_preexisting="$(boolean_command_state test -e "$BBR_SYSCTL_FILE")"
  bbr_modules_preexisting="$(boolean_command_state test -e "$BBR_MODULES_FILE")"
  conntrack_sysctl_preexisting="$(boolean_command_state test -e "$CONNTRACK_SYSCTL_FILE")"
  conntrack_modprobe_preexisting="$(boolean_command_state test -e "$CONNTRACK_MODPROBE_FILE")"
  conntrack_modules_preexisting="$(boolean_command_state test -e "$CONNTRACK_MODULES_FILE")"
  conntrack_helper_preexisting="$(boolean_command_state test -e "$CONNTRACK_HELPER_FILE")"
  conntrack_service_preexisting="$(boolean_command_state test -e "$CONNTRACK_SERVICE_FILE")"

  content="# Hguard pre-install state. Parsed as data; never sourced.
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
CONNTRACK_SYSCTL_PREEXISTED='${conntrack_sysctl_preexisting}'
CONNTRACK_MODPROBE_PREEXISTED='${conntrack_modprobe_preexisting}'
CONNTRACK_MODULES_PREEXISTED='${conntrack_modules_preexisting}'
CONNTRACK_HELPER_PREEXISTED='${conntrack_helper_preexisting}'
CONNTRACK_SERVICE_PREEXISTED='${conntrack_service_preexisting}'
"
  atomic_write "$HGUARD_STATE_FILE" 600 "$content"
  atomic_write "$HGUARD_MANAGED_RULES" 600 "# UFW rules added by Hguard
"
  info "Recorded pre-install service and managed-file state."
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Please run Hguard as root."
  fi
}

check_ubuntu_lts() {
  local os_release="${HGUARD_ETC_ROOT}/os-release"

  [ -f "$os_release" ] || error "Cannot detect Ubuntu: ${os_release} is missing."
  # shellcheck disable=SC1090
  . "$os_release"
  [ "${ID:-}" = "ubuntu" ] || error "Unsupported OS: ${PRETTY_NAME:-unknown}. Ubuntu LTS is required."
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) error "该版本尚未经过测试: ${PRETTY_NAME:-unknown}. Supported: Ubuntu 22.04, 24.04." ;;
  esac
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

  info "User ${username} already exists. Hguard will preserve its password, home and existing SSH keys."
  if [ ! -t 0 ]; then
    return 0
  fi

  read -r -p "输入 YES 使用现有用户 ${username}，其他输入取消：" answer
  [ "$answer" = "YES" ] || error "Cancelled before modifying the existing user."
}

resolve_managed_user() {
  local configured_user=""
  local selection

  if ! configured_user="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then
    configured_user=""
  fi
  PREVIOUS_MANAGED_USER="$configured_user"

  if [ -n "$REQUESTED_NEW_USER" ]; then
    validate_username "$REQUESTED_NEW_USER" || error "Invalid NEW_USER value: ${REQUESTED_NEW_USER}"
    NEW_USER="$REQUESTED_NEW_USER"
  elif [ -n "$configured_user" ]; then
    validate_username "$configured_user" || error "Configured NEW_USER is invalid. Repair ${HGUARD_CONFIG_FILE}."
    NEW_USER="$configured_user"
    info "检测到 Hguard 管理用户：${NEW_USER}"
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
  # Only confirm when NEW_USER is an existing OS account Hguard did not
  # already manage. When it's the same user recorded in config.env, the
  # "1. 继续使用" menu choice above (or a non-interactive rerun with the
  # same NEW_USER) is already that confirmation - asking again with a
  # literal "YES" is a redundant second gate that has caused mis-taps.
  if [ "$NEW_USER" != "$PREVIOUS_MANAGED_USER" ] && id "$NEW_USER" >/dev/null 2>&1; then
    confirm_existing_user "$NEW_USER"
  fi
}

validate_sudo_mode() {
  case "${1:-}" in
    password|passwordless) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_passwordless_sudo_risk() {
  local confirmation

  printf '%s\n' '免密码 sudo 意味着任何获得该用户 SSH 私钥的人都可以立即取得 root 权限。' >&2
  read -r -p "请输入 I UNDERSTAND 继续：" confirmation
  [ "$confirmation" = "I UNDERSTAND" ]
}

prompt_initial_sudo_mode() {
  local selection

  while true; do
    printf '%s\n' '请选择管理员 sudo 模式：' >&2
    printf '%s\n' '1. 密码 sudo（推荐）' '2. 免密码 sudo（高风险）' >&2
    read -r -p "请选择 [1]：" selection
    case "${selection:-1}" in
      1) printf 'password\n'; return 0 ;;
      2)
        if confirm_passwordless_sudo_risk; then
          printf 'passwordless\n'
          return 0
        fi
        warn "未输入精确确认；未启用免密码 sudo。" >&2
        ;;
      *) warn "无效选择，请重新选择。" >&2 ;;
    esac
  done
}

prompt_rerun_sudo_mode() {
  local current_mode="$1"
  local selection

  while true; do
    printf '当前 sudo 模式：%s\n' "$current_mode" >&2
    printf '%s\n' \
      '1. 保持当前模式' \
      '2. 切换为密码 sudo' \
      '3. 切换为免密码 sudo' \
      '4. 取消' >&2
    read -r -p "请选择 [1]：" selection
    case "${selection:-1}" in
      1) printf '%s\n' "$current_mode"; return 0 ;;
      2) printf 'password\n'; return 0 ;;
      3)
        if confirm_passwordless_sudo_risk; then
          printf 'passwordless\n'
          return 0
        fi
        warn "未输入精确确认；未启用免密码 sudo。" >&2
        ;;
      4) return 2 ;;
      *) warn "无效选择，请重新选择。" >&2 ;;
    esac
  done
}

resolve_sudo_mode() {
  local configured_mode=""
  local selected_mode

  if [ -f "$HGUARD_CONFIG_FILE" ]; then
    if configured_mode="$(read_env_value "$HGUARD_CONFIG_FILE" SUDO_MODE 2>/dev/null)"; then
      validate_sudo_mode "$configured_mode" || error "Configured SUDO_MODE is invalid. Repair ${HGUARD_CONFIG_FILE}."
      PREVIOUS_SUDO_MODE="$configured_mode"
      if [ -t 0 ]; then
        if ! selected_mode="$(prompt_rerun_sudo_mode "$configured_mode")"; then
          error "Installation cancelled."
        fi
        SUDO_MODE="$selected_mode"
      else
        SUDO_MODE="$configured_mode"
      fi
    else
      PREVIOUS_SUDO_MODE=""
      info "Existing configuration has no validated SUDO_MODE; sudo mode selection will run again."
      if [ -t 0 ]; then
        SUDO_MODE="$(prompt_initial_sudo_mode)"
      else
        SUDO_MODE="password"
        info "No interactive terminal; using the safe password sudo request. It will not be persisted until validation succeeds."
      fi
    fi
  elif [ -t 0 ]; then
    SUDO_MODE="$(prompt_initial_sudo_mode)"
  else
    SUDO_MODE="password"
    info "No interactive terminal; using the default password sudo mode."
  fi

  validate_sudo_mode "$SUDO_MODE" || error "Resolved sudo mode is invalid."
  info "Selected sudo mode: ${SUDO_MODE}."
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
  ensure_directory "${HGUARD_RUN_ROOT}/sshd" 755
}

finalized_port_state_matches() {
  local configured_port="$1"
  local installed_status

  [ -f "$HGUARD_INSTALLED_MARKER" ] || return 1
  [ ! -e "$HGUARD_PENDING_PORT_MARKER" ] || return 1
  [ "$configured_port" = "$SSH_PORT" ] || return 1
  if ! installed_status="$(awk 'NF {print; exit}' "$HGUARD_INSTALLED_MARKER" 2>/dev/null)"; then
    installed_status=""
  fi
  case "$installed_status" in
    success|success-with-warnings) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_port_migration_requirement() {
  local configured_port="$1"

  PORT_MIGRATION_REQUIRED="false"
  if [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ] \
    && ! finalized_port_state_matches "$configured_port"; then
    PORT_MIGRATION_REQUIRED="true"
  fi
}

resolve_ssh_ports() {
  local configured_port configured_original

  if ! configured_port="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)"; then
    configured_port=""
  fi
  if ! configured_original="$(read_env_value "$HGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)"; then
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

  resolve_port_migration_requirement "$configured_port"
  info "SSH port plan: original=${ORIGINAL_SSH_PORT}, target=${SSH_PORT}, migration-required=${PORT_MIGRATION_REQUIRED}"
}

# Fixed scope, shared by `hguard update` and the apt Post-Invoke hook: only
# these five packages are ever subject to an update-time upgrade or a
# version-change check. Never the kernel, never Hguard's own scripts (there
# is no self-update).
HGUARD_MANAGED_PACKAGES="openssh-server ufw fail2ban python3-systemd sudo"

# "<installed> <candidate>" for one package, via apt-cache policy - a single
# read-only call gives both without an install/simulate side-effect risk.
package_versions() {
  local package="$1"
  local policy_output installed candidate

  policy_output="$(apt-cache policy "$package" 2>/dev/null)" || return 1
  installed="$(printf '%s\n' "$policy_output" | awk '/^ *Installed:/ {print $2; exit}')"
  candidate="$(printf '%s\n' "$policy_output" | awk '/^ *Candidate:/ {print $2; exit}')"
  [ -n "$installed" ] && [ "$installed" != "(none)" ] || return 1
  printf '%s %s\n' "$installed" "$candidate"
}

# Packages (of HGUARD_MANAGED_PACKAGES) whose installed and candidate
# versions differ, one per line as "<package> <installed> <candidate>".
upgradable_managed_packages() {
  local package installed candidate
  for package in $HGUARD_MANAGED_PACKAGES; do
    # `read ... <<< "$cmdsub"` always "succeeds" (the herestring is never
    # truly empty - it has at least a newline), even when package_versions
    # failed and printed nothing; check $installed itself instead of
    # relying on read's exit status.
    read -r installed candidate <<< "$(package_versions "$package" 2>/dev/null)"
    [ -n "$installed" ] || continue
    [ "$installed" != "$candidate" ] || continue
    printf '%s %s %s\n' "$package" "$installed" "$candidate"
  done
}

# A single comparable snapshot of every managed package's installed
# version, e.g. "openssh-server=1:9.6p1 ufw=0.36.2 ...". Used by the apt
# hook to detect whether anything changed since the last apt run without
# caring what the versions actually are.
managed_package_version_snapshot() {
  local package installed candidate
  for package in $HGUARD_MANAGED_PACKAGES; do
    read -r installed candidate <<< "$(package_versions "$package")" || true
    printf '%s=%s ' "$package" "${installed:-absent}"
  done
}

upgrade_system() {
  info "Updating Ubuntu packages and installing Hguard dependencies..."
  export NEEDRESTART_MODE=l
  apt-get update
  if [ ! -s "$HGUARD_INSTALLED_MARKER" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade -y --with-new-pkgs
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y sudo curl wget git vim nano unzip ufw fail2ban python3-systemd htop jq ca-certificates gnupg lsb-release net-tools iproute2 openssh-server
}

fail2ban_systemd_backend_available() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import systemd.journal' >/dev/null 2>&1
}

ensure_managed_user() {
  if id "$NEW_USER" >/dev/null 2>&1; then
    info "Reconciling existing user ${NEW_USER}."
  else
    [ -t 0 ] || error "Creating a new administrator requires a trusted interactive terminal. Hguard does not accept sudo risk confirmation or passwords through automation variables."
    info "Creating administrator user ${NEW_USER}."
    adduser --disabled-password --gecos "" "$NEW_USER"
  fi

  usermod -aG sudo "$NEW_USER"
  validate_existing_user_account "$NEW_USER"
}

managed_user_home() {
  getent passwd "$NEW_USER" | awk -F: '{print $6}'
}

# Prints the subset of an authorized_keys file's lines that are usable for
# interactive login: non-comment, non-blank, and without a forced "command="
# option. Cloud images (AWS, etc.) ship root's authorized_keys with a
# command= line that prints a warning and disconnects; copying that line
# verbatim into the new admin's authorized_keys locks them out on first
# login. Options are comma-joined with no unquoted whitespace before the
# command value, so the forced-command option always lands in the line's
# first whitespace-delimited field - checking that field for "command=" is
# enough to find it without a full authorized_keys options parser.
usable_pubkey_lines() {
  local file="$1" lines
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  lines="$(awk 'NF && $1 !~ /^#/ && $1 !~ /command=/' "$file" 2>/dev/null)"
  [ -n "$lines" ] || return 1
  printf '%s\n' "$lines"
}

# Prints the path of the authorized_keys file to source the new admin's
# login key(s) from: root's, or - when root has none usable (e.g. a cloud
# image's forced-command key) - the sudo-invoking user's, as a fallback.
resolve_admin_pubkey_source() {
  local sudo_user_home sudo_authorized_keys

  if usable_pubkey_lines "$ROOT_AUTHORIZED_KEYS" >/dev/null; then
    printf '%s\n' "$ROOT_AUTHORIZED_KEYS"
    return 0
  fi

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    sudo_user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | awk -F: '{print $6}')"
    if [ -n "$sudo_user_home" ] && [ ! -L "${sudo_user_home}/.ssh" ]; then
      sudo_authorized_keys="${sudo_user_home}/.ssh/authorized_keys"
      if usable_pubkey_lines "$sudo_authorized_keys" >/dev/null; then
        printf '%s\n' "$sudo_authorized_keys"
        return 0
      fi
    fi
  fi

  return 1
}

check_root_ssh_key() {
  local pubkey_source tmp

  pubkey_source="$(resolve_admin_pubkey_source)" \
    || error "root 的 ${ROOT_AUTHORIZED_KEYS} 中的公钥带有云镜像强制的登录限制（command= 选项），无法用于交互式登录，且当前 sudo 用户（SUDO_USER）也没有可用的公钥。请在其中之一添加一个不带 command= 限制的公钥后重试。"

  tmp="$(mktemp)"
  usable_pubkey_lines "$pubkey_source" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "${pubkey_source} 中没有可被 ssh-keygen 解析的公钥条目。"
  fi
  rm -f "$tmp"
}

# Removes any line from the admin's authorized_keys that is verbatim
# identical to a forced-command line in root's authorized_keys - residue
# from a previous Hguard run that copied such a line before this check
# existed. Every other line is left untouched.
purge_root_forced_command_residue() {
  local target_file="$1" root_file="$2" restricted_tmp filtered_tmp

  [ -f "$target_file" ] && [ -f "$root_file" ] || return 0

  restricted_tmp="$(mktemp)"
  awk 'NF && $1 !~ /^#/ && $1 ~ /command=/' "$root_file" > "$restricted_tmp"
  if [ -s "$restricted_tmp" ]; then
    filtered_tmp="$(mktemp)"
    grep -Fxvf "$restricted_tmp" "$target_file" > "$filtered_tmp" 2>/dev/null || true
    if ! cmp -s "$target_file" "$filtered_tmp"; then
      chmod 600 "$filtered_tmp"
      chown --reference="$target_file" "$filtered_tmp" 2>/dev/null || true
      mv -f "$filtered_tmp" "$target_file"
      info "Removed a residual forced-command line from ${target_file}."
    else
      rm -f "$filtered_tmp"
    fi
  fi
  rm -f "$restricted_tmp"
}

root_pubkey_sync_required() {
  local user_home authorized_keys
  [ -s "$HGUARD_INSTALLED_MARKER" ] || return 0
  user_home="$(managed_user_home)"
  authorized_keys="${user_home}/.ssh/authorized_keys"
  [ -s "$authorized_keys" ] || return 0
  return 1
}

# The admin's own ~/.ssh is not a Hguard-owned directory like the ones
# ensure_directory manages (which it chowns to root:root) - it must stay
# owned by the admin, or sshd (reading authorized_keys as that user) will
# refuse to even enter the directory and reject an otherwise-valid key.
ensure_admin_ssh_directory() {
  local ssh_directory="$1"

  mkdir -p "$ssh_directory"
  # Re-check for a symlink immediately before chown/chmod, not just in the
  # caller before this function runs: mkdir -p is a no-op if the path
  # already exists in any form, and chown/chmod follow a symlink by
  # default, so a path swapped to a symlink in the window since the
  # caller's own check would make these operations run - as root - against
  # whatever attacker-chosen target the symlink points to.
  [ ! -L "$ssh_directory" ] || error "${ssh_directory} is a symlink; refusing to follow it."
  chown "${NEW_USER}:${NEW_USER}" "$ssh_directory"
  chmod 700 "$ssh_directory"
}

configure_authorized_keys() {
  local user_home ssh_directory authorized_keys temporary_file pubkey_source

  check_root_ssh_key
  pubkey_source="$(resolve_admin_pubkey_source)"
  user_home="$(managed_user_home)"
  if [ -z "$user_home" ] || [ "$user_home" = "/" ]; then
    error "Could not resolve a safe home directory for ${NEW_USER}."
  fi
  ssh_directory="${user_home}/.ssh"
  authorized_keys="${ssh_directory}/authorized_keys"
  if [ -L "$ssh_directory" ]; then
    error "${ssh_directory} is a symlink; refusing to follow it."
  fi
  if [ -L "$authorized_keys" ]; then
    error "${authorized_keys} is a symlink; refusing to follow it."
  fi

  # ensure_directory is for root-owned Hguard directories; it chowns to
  # root:root, which would leave the admin's own ~/.ssh unreadable by sshd
  # under their identity. Every return path below - including the "leave
  # untouched" rerun fast path - must go through this instead.
  ensure_admin_ssh_directory "$ssh_directory"

  purge_root_forced_command_residue "$authorized_keys" "$ROOT_AUTHORIZED_KEYS"

  if ! root_pubkey_sync_required; then
    if [ -f "$authorized_keys" ]; then
      chown "${NEW_USER}:${NEW_USER}" "$authorized_keys"
      chmod 600 "$authorized_keys"
    fi
    info "Administrator authorized_keys left untouched (not first install, existing keys present)."
    return 0
  fi

  temporary_file="$(mktemp "${authorized_keys}.tmp.XXXXXX")"
  if [ -f "$authorized_keys" ]; then
    { cat "$authorized_keys"; usable_pubkey_lines "$pubkey_source"; } | awk 'NF && !seen[$0]++' > "$temporary_file"
  else
    usable_pubkey_lines "$pubkey_source" | awk 'NF && !seen[$0]++' > "$temporary_file"
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
  printf '%s/hguard-%s\n' "$SUDOERS_DIR" "$NEW_USER"
}

legacy_sudoers_file_for_user() {
  # This is a VPSGuard-era filename (predates the vpsguard-<user> scheme,
  # two generations back from today's hguard-<user>), not an Hguard name -
  # kept as-is so a sudoers file from that old generation still gets found
  # and cleaned up, same as before the rename.
  printf '%s/90-vpsguard-%s\n' "$SUDOERS_DIR" "$NEW_USER"
}

managed_file_is_owned() {
  local file="$1"
  [ -f "$file" ] && head -n 2 "$file" | grep -Eq "^# ${MANAGED_MARKER}( |\$)"
}

# Like managed_file_is_owned, but also recognizes a VPSGuard-era (pre-rename)
# file. Only for migration/status/uninstall callers that need to find or
# report on a leftover old-generation file; every current-generation write
# or validation path keeps using managed_file_is_owned (current marker only).
any_generation_marker_owns() {
  local file="$1"
  [ -f "$file" ] && head -n 2 "$file" | grep -Eq "^# (${MANAGED_MARKER}|${LEGACY_MANAGED_MARKER})( |\$)"
}

legacy_marker_owns() {
  local file="$1"
  [ -f "$file" ] && head -n 2 "$file" | grep -Eq "^# ${LEGACY_MANAGED_MARKER}( |\$)"
}

# Every path a VPSGuard-managed file could exist at (D3's third bullet):
# used by `hguard status` to warn if one reappears after migration - e.g.
# someone ran the old 0.3.7 installer again. Only reports what's actually
# there; never removes anything.
legacy_vpsguard_files_present() {
  local new_user path candidates

  if ! new_user="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then new_user=""; fi
  candidates="$VPSGUARD_LEGACY_SSHD_CONFIG
$VPSGUARD_LEGACY_SSH_SOCKET_OVERRIDE
$VPSGUARD_LEGACY_FAIL2BAN_JAIL
$VPSGUARD_LEGACY_BBR_SYSCTL_FILE
$VPSGUARD_LEGACY_BBR_MODULES_FILE
$VPSGUARD_LEGACY_CONNTRACK_SYSCTL_FILE
$VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE
$VPSGUARD_LEGACY_CONNTRACK_MODULES_FILE
$VPSGUARD_LEGACY_CONNTRACK_HELPER_FILE
$VPSGUARD_LEGACY_CONNTRACK_SERVICE_FILE"
  if [ -n "$new_user" ]; then
    candidates="${candidates}
${SUDOERS_DIR}/vpsguard-${new_user}
${SUDOERS_DIR}/90-vpsguard-${new_user}"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    legacy_marker_owns "$path" && printf '%s\n' "$path"
  done <<< "$candidates"
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

standard_sudo_policy_available() {
  local policy_output

  if ! policy_output="$(LC_ALL=C sudo -l -U "$NEW_USER" 2>/dev/null)"; then
    return 1
  fi
  printf '%s\n' "$policy_output" | sudo_policy_has_full_admin_from_text
}

clear_user_sudo_cache() {
  sudo -u "$NEW_USER" sudo -k >/dev/null 2>&1
}

passwordless_sudo_effective() {
  clear_user_sudo_cache || return 1
  sudo -u "$NEW_USER" sudo -n true >/dev/null 2>&1 || return 1
  sudo -u "$NEW_USER" sudo -n -i true >/dev/null 2>&1
}

passwordless_sudo_denied() {
  clear_user_sudo_cache || return 1
  ! sudo -u "$NEW_USER" sudo -n true >/dev/null 2>&1
}

sudoers_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

validate_passwordless_sudoers_file() {
  local sudoers_file="$1"
  local expected_line

  expected_line="${NEW_USER} ALL=(ALL:ALL) NOPASSWD: ALL"
  managed_file_is_owned "$sudoers_file" || return 1
  [ "$(sudoers_file_mode "$sudoers_file")" = "440" ] || return 1
  [ "$(grep -Fxc "$expected_line" "$sudoers_file")" -eq 1 ] || return 1
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    [ "$(stat -c '%U:%G' "$sudoers_file" 2>/dev/null)" = "root:root" ] || return 1
  fi
  visudo -cf "$sudoers_file" >/dev/null 2>&1
}

ensure_sudo_password() {
  if user_password_is_set; then
    info "Administrator ${NEW_USER} has a password for standard sudo authentication."
    return 0
  fi

  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    [ -t 0 ] || error "Administrator ${NEW_USER} has no usable password. Set one with 'passwd ${NEW_USER}' from a trusted console, then rerun Hguard."
  fi
  warn "Hguard uses standard password-authenticated sudo. Set a strong password for ${NEW_USER}; it is not used for SSH login."
  warn "部分云镜像会强制检查密码强度，建议使用随机生成的强密码（例如 openssl rand -base64 18），避免因密码过弱被拒绝。"
  if ! passwd "$NEW_USER"; then
    warn "Could not set the sudo password for ${NEW_USER}."
    return 1
  fi
  if ! user_password_is_set; then
    warn "Password state for ${NEW_USER} is still locked or unavailable."
    return 1
  fi
}

confirm_sudo_password_authentication() {
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    [ -t 0 ] || return 1
    info "Enter the password for ${NEW_USER} once to validate 'sudo -i' authentication before SSH is changed."
  fi
  clear_user_sudo_cache || return 1
  sudo -u "$NEW_USER" sudo -v || return 1
  clear_user_sudo_cache
}

restore_sudoers_backup() {
  local backup="$1"
  local destination="$2"

  if [ -n "$backup" ] && [ -e "$backup" ]; then
    mv -f "$backup" "$destination"
  else
    rm -f "$destination"
  fi
}

configure_passwordless_sudo() {
  local sudoers_file backup=""
  local content

  sudoers_file="$(sudoers_file_for_user)"
  if [ -e "$sudoers_file" ] && ! managed_file_is_owned "$sudoers_file"; then
    warn "Refusing to overwrite an unrecognized sudoers file: ${sudoers_file}"
    return 1
  fi
  if [ -e "$sudoers_file" ]; then
    if ! backup="$(mktemp "${sudoers_file}.backup.XXXXXX")" \
      || ! cp -p "$sudoers_file" "$backup"; then
      [ -z "$backup" ] || rm -f "$backup"
      warn "Could not create a sudoers rollback copy."
      return 1
    fi
  fi

  content="# Managed by Hguard ${HGUARD_VERSION}; passwordless sudo mode.
${NEW_USER} ALL=(ALL:ALL) NOPASSWD: ALL
"
  if ! atomic_write "$sudoers_file" 440 "$content"; then
    restore_sudoers_backup "$backup" "$sudoers_file"
    warn "Could not atomically write ${sudoers_file}; the previous state was restored."
    return 1
  fi
  if validate_passwordless_sudoers_file "$sudoers_file" \
    && visudo -c >/dev/null 2>&1 \
    && passwordless_sudo_effective; then
    [ -z "$backup" ] || rm -f "$backup"
    info "Full passwordless sudo is configured in ${sudoers_file}."
    return 0
  fi

  restore_sudoers_backup "$backup" "$sudoers_file"
  visudo -c >/dev/null 2>&1 || warn "The previous sudoers state was restored, but global validation still fails."
  warn "Passwordless sudo validation failed; the previous sudoers state was restored."
  return 1
}

detect_foreign_nopasswd_sudoers() {
  local file
  [ -d "$SUDOERS_DIR" ] || return 1
  for file in "$SUDOERS_DIR"/*; do
    [ -f "$file" ] || continue
    managed_file_is_owned "$file" && continue
    if grep -Eq "^[[:space:]]*${NEW_USER}[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+NOPASSWD:" "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}

# Run as a preflight, before upgrade_system: a cloud-init NOPASSWD sudoers
# conflict with password mode is cheap to detect from SUDOERS_DIR content
# alone and should fail fast, not after a multi-minute apt upgrade already ran.
check_sudo_mode_compatibility() {
  local foreign_nopasswd

  [ "$SUDO_MODE" = "password" ] || return 0
  if foreign_nopasswd="$(detect_foreign_nopasswd_sudoers)"; then
    error "检测到 ${foreign_nopasswd} 已授予 ${NEW_USER} 免密码 sudo（通常来自 cloud-init），与 password 模式冲突。请手动检查该文件并决定是否删除或修改后重试；Hguard 不会自动修改它。"
  fi
}

configure_password_sudo() {
  local sudoers_file legacy_file backup="" legacy_backup=""
  local foreign_nopasswd

  sudoers_file="$(sudoers_file_for_user)"
  legacy_file="$(legacy_sudoers_file_for_user)"
  if [ -e "$sudoers_file" ] && ! managed_file_is_owned "$sudoers_file"; then
    warn "Refusing to remove an unrecognized sudoers file: ${sudoers_file}"
    return 1
  fi
  if [ -e "$legacy_file" ] && ! managed_file_is_owned "$legacy_file"; then
    warn "Refusing to remove an unrecognized legacy sudoers file: ${legacy_file}"
    return 1
  fi
  if foreign_nopasswd="$(detect_foreign_nopasswd_sudoers)"; then
    warn "检测到 ${foreign_nopasswd} 已授予 ${NEW_USER} 免密码 sudo（通常来自 cloud-init），与 password 模式冲突。请手动检查该文件并决定是否删除或修改后重试；Hguard 不会自动修改它。"
    return 1
  fi

  ensure_sudo_password || return 1
  user_in_sudo_group || return 1
  visudo -c >/dev/null 2>&1 || return 1
  standard_sudo_policy_available || return 1

  if [ -e "$sudoers_file" ]; then
    if ! backup="$(mktemp "${sudoers_file}.backup.XXXXXX")" \
      || ! cp -p "$sudoers_file" "$backup"; then
      [ -z "$backup" ] || rm -f "$backup"
      warn "Could not back up ${sudoers_file}; no sudoers file was changed."
      return 1
    fi
  fi
  if [ -e "$legacy_file" ]; then
    if ! legacy_backup="$(mktemp "${legacy_file}.backup.XXXXXX")" \
      || ! cp -p "$legacy_file" "$legacy_backup"; then
      [ -z "$legacy_backup" ] || rm -f "$legacy_backup"
      [ -z "$backup" ] || rm -f "$backup"
      warn "Could not back up ${legacy_file}; no sudoers file was changed."
      return 1
    fi
  fi
  if ! rm -f "$sudoers_file" "$legacy_file"; then
    restore_sudoers_backup "$backup" "$sudoers_file"
    restore_sudoers_backup "$legacy_backup" "$legacy_file"
    warn "Could not stage password sudo safely; the previous sudoers state was restored."
    return 1
  fi

  if visudo -c >/dev/null 2>&1 \
    && confirm_sudo_password_authentication \
    && passwordless_sudo_denied; then
    [ -z "$backup" ] || rm -f "$backup"
    [ -z "$legacy_backup" ] || rm -f "$legacy_backup"
    info "Standard password-authenticated sudo is configured for ${NEW_USER}."
    return 0
  fi

  restore_sudoers_backup "$backup" "$sudoers_file"
  restore_sudoers_backup "$legacy_backup" "$legacy_file"
  visudo -c >/dev/null 2>&1 || warn "The previous sudoers state was restored, but global validation still fails."
  warn "Password sudo validation failed; the previous sudoers state was restored."
  return 1
}

configure_sudo() {
  user_in_sudo_group || error "Administrator ${NEW_USER} is not a member of the sudo group."
  case "$SUDO_MODE" in
    password) configure_password_sudo || error "Could not safely configure password sudo." ;;
    passwordless) configure_passwordless_sudo || error "Could not safely configure passwordless sudo." ;;
    *) error "Unsupported sudo mode: ${SUDO_MODE}" ;;
  esac
}

verify_password_sudo_configuration() {
  [ ! -e "$(sudoers_file_for_user)" ] || return 1
  [ ! -e "$(legacy_sudoers_file_for_user)" ] || return 1
  user_in_sudo_group || return 1
  user_password_is_set || return 1
  visudo -c >/dev/null 2>&1 || return 1
  standard_sudo_policy_available || return 1
  passwordless_sudo_denied
}

verify_passwordless_sudo_configuration() {
  local sudoers_file

  sudoers_file="$(sudoers_file_for_user)"
  user_in_sudo_group || return 1
  validate_passwordless_sudoers_file "$sudoers_file" || return 1
  visudo -c >/dev/null 2>&1 || return 1
  passwordless_sudo_effective
}

verify_sudo_configuration() {
  case "$SUDO_MODE" in
    password) verify_password_sudo_configuration ;;
    passwordless) verify_passwordless_sudo_configuration ;;
    *) return 1 ;;
  esac
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

  [ -f "$HGUARD_MANAGED_RULES" ] || atomic_write "$HGUARD_MANAGED_RULES" 600 "# UFW rules added by Hguard
"
  grep -Fxq "$rule" "$HGUARD_MANAGED_RULES" && return 0
  temporary_file="$(mktemp "${HGUARD_MANAGED_RULES}.tmp.XXXXXX")"
  awk 'NF && !seen[$0]++' "$HGUARD_MANAGED_RULES" > "$temporary_file"
  printf '%s\n' "$rule" >> "$temporary_file"
  chmod 600 "$temporary_file"
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$HGUARD_MANAGED_RULES"
}

remove_managed_rule_record() {
  local rule="$1"
  local temporary_file

  [ -f "$HGUARD_MANAGED_RULES" ] || return 0
  temporary_file="$(mktemp "${HGUARD_MANAGED_RULES}.tmp.XXXXXX")"
  awk -v unwanted="$rule" '$0 != unwanted' "$HGUARD_MANAGED_RULES" > "$temporary_file"
  chmod 600 "$temporary_file"
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$HGUARD_MANAGED_RULES"
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

parse_allow_ports() {
  local raw="$1" token port proto
  IFS=',' read -ra __tokens <<<"$raw"
  for token in "${__tokens[@]}"; do
    [ -n "$token" ] || continue
    port="${token%%/*}"
    proto="${token##*/}"
    case "$proto" in tcp|udp) ;; *) return 1 ;; esac
    validate_ssh_port "$port" || return 1
    printf '%s/%s\n' "$port" "$proto"
  done
}

survey_foreign_listening_ports() {
  local output
  # ss -ltnupH already covers both TCP and UDP listeners (via -t and -u
  # together) with a Netid column, so a second ss -lunupH call is both
  # redundant and wrong: without -t, that output has no Netid column, which
  # shifts every field left by one - $5 (meant to be the local address) ends
  # up holding the peer address instead, usually "0.0.0.0:*", and $1 (meant
  # to be the protocol) holds the state (e.g. "UNCONN"), so every port from
  # that call was misread as TCP port "*".
  output="${SS_LISTEN_ALL_OUTPUT_OVERRIDE:-$(ss -ltnupH 2>/dev/null)}"
  printf '%s\n' "$output" | awk -v ssh_port="$SSH_PORT" '
    {
      proto = (tolower($1) == "udp") ? "udp" : "tcp"
      addr = $5
      n = split(addr, parts, ":")
      port = parts[n]
      host = substr(addr, 1, length(addr) - length(port) - 1)
      # Strip an interface-scoped address'"'"'s %ifname suffix (e.g.
      # "127.0.0.53%lo" or a bracketed IPv6 "[fe80::1%eth0]") and IPv6
      # brackets, so the loopback check below matches the real address
      # instead of silently failing against a decorated one.
      sub(/%[^]]*/, "", host)
      gsub(/[][]/, "", host)
      if (host ~ /^127\./ || host == "::1") next
      if (port == ssh_port) next
      process = "unknown"
      if (match($0, /users:\(\("[^"]+"/)) {
        process = substr($0, RSTART + 9, RLENGTH - 10)
      }
      key = port "/" proto
      if (!(key in seen)) { seen[key] = process; order[++n2] = key }
    }
    END { for (i = 1; i <= n2; i++) print order[i] "\t" seen[order[i]] }
  '
}

# Accepts the same token format as ALLOW_PORTS: a bare port number (allow
# every protocol the survey detected listening on it - previously this
# silently allowed only the first-detected protocol, i.e. TCP whenever both
# TCP and UDP were listening on the same port number, since survey_foreign_
# listening_ports lists TCP listeners before UDP ones) or port/tcp,
# port/udp to allow only that specific protocol.
select_ports_from_survey() {
  local survey="$1" selection="$2" chosen port proto matches
  [ -n "$selection" ] || return 0
  IFS=',' read -ra __chosen <<<"$selection"
  for chosen in "${__chosen[@]}"; do
    chosen="$(printf '%s' "$chosen" | tr -d '[:space:]')"
    [ -n "$chosen" ] || continue
    if [[ "$chosen" == */* ]]; then
      port="${chosen%%/*}"
      proto="${chosen##*/}"
      case "$proto" in
        tcp|udp) ;;
        *) error "所选端口 ${chosen} 的协议无效，只接受 tcp 或 udp。" ;;
      esac
      matches="$(printf '%s\n' "$survey" | awk -F'\t' -v p="${port}/${proto}" '$1 == p {print $1; exit}')"
    else
      matches="$(printf '%s\n' "$survey" | awk -F'\t' -v p="$chosen" '$1 ~ ("^" p "/") {print $1}')"
    fi
    [ -n "$matches" ] || error "所选端口 ${chosen} 不在检测到的列表中。"
    printf '%s\n' "$matches"
  done
}

configure_ufw_before_ssh() {
  local active="false"
  local foreign ports_to_allow="" line port proto

  if ufw_is_active; then
    active="true"
  fi

  if [ "$active" != "true" ]; then
    foreign="$(survey_foreign_listening_ports)"
    if [ -n "$foreign" ]; then
      if [ -n "$REQUESTED_ALLOW_PORTS" ]; then
        ports_to_allow="$(parse_allow_ports "$REQUESTED_ALLOW_PORTS")" \
          || error "ALLOW_PORTS format is invalid. Example: ALLOW_PORTS=443/tcp,8443/udp bash install.sh"
      elif [ "$ALLOW_SSH_ONLY" = "true" ]; then
        ports_to_allow=""
      elif [ -t 0 ]; then
        printf '检测到以下非 SSH 端口正在监听：\n'
        printf '%s\n' "$foreign" | awk -F'\t' '{print "  - " $1 " (" $2 ")"}'
        printf '输入要放行的端口（逗号分隔，格式与 ALLOW_PORTS 一致：443、443/tcp 或 443/udp；纯端口号表示放行该端口上检测到的所有协议，可留空表示全部不放行，例如 443,8443/udp）：'
        read -r selection
        ports_to_allow="$(select_ports_from_survey "$foreign" "$selection")"
      else
        error "检测到非 SSH 端口正在监听，但未指定 ALLOW_PORTS 或 --ssh-only。示例：ALLOW_PORTS=443/tcp,8443/udp bash install.sh 或 bash install.sh --ssh-only"
      fi
    fi
  fi

  ensure_ufw_tcp_rule "$SSH_PORT"
  if [ "$PORT_MIGRATION_REQUIRED" = "true" ]; then
    ensure_ufw_tcp_rule "$ORIGINAL_SSH_PORT"
  fi
  if [ -n "$ports_to_allow" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      port="${line%%/*}"
      proto="${line##*/}"
      ufw allow "${port}/${proto}"
      record_managed_rule "${port}/${proto}"
    done <<<"$ports_to_allow"
  fi

  if [ "$active" != "true" ]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
  fi
  ufw_is_active || error "UFW is not active after configuration."
}

write_hguard_sshd_config() {
  local keep_old_port="${1:-false}"
  local port_lines content

  assert_managed_or_absent "$HGUARD_SSHD_CONFIG"
  port_lines="Port ${SSH_PORT}"
  if [ "$keep_old_port" = "true" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    port_lines="${port_lines}
Port ${ORIGINAL_SSH_PORT}"
  fi

  content="# Managed by Hguard ${HGUARD_VERSION}. Do not edit; change ${HGUARD_CONFIG_FILE} and rerun.
${port_lines}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
"
  atomic_write "$HGUARD_SSHD_CONFIG" 600 "$content"
}

ensure_hguard_sshd_include_first() {
  local begin_count end_count begin_line end_line existing_content content mode

  [ -f "$SSHD_CONFIG" ] || error "OpenSSH server config is missing: ${SSHD_CONFIG}"
  if ! begin_count="$(grep -Fxc "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"; then begin_count=0; fi
  if ! end_count="$(grep -Fxc "$SSHD_INCLUDE_END" "$SSHD_CONFIG")"; then end_count=0; fi
  if { [ "$begin_count" -ne 0 ] || [ "$end_count" -ne 0 ]; } \
    && { [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; }; then
    error "Refusing to modify malformed Hguard include markers in ${SSHD_CONFIG}."
  fi
  if [ "$begin_count" -eq 1 ]; then
    begin_line="$(grep -Fn "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG" | cut -d: -f1)"
    end_line="$(grep -Fn "$SSHD_INCLUDE_END" "$SSHD_CONFIG" | cut -d: -f1)"
    [ "$begin_line" -lt "$end_line" ] || error "Hguard include markers are out of order in ${SSHD_CONFIG}."
  fi

  existing_content="$(awk -v begin="$SSHD_INCLUDE_BEGIN" -v end="$SSHD_INCLUDE_END" '
    $0 == begin {inside=1; next}
    $0 == end {inside=0; next}
    !inside {print}
  ' "$SSHD_CONFIG")"
  content="${SSHD_INCLUDE_BEGIN}
Include ${HGUARD_SSHD_CONFIG}
${SSHD_INCLUDE_END}
${existing_content}
"
  if ! mode="$(stat -c '%a' "$SSHD_CONFIG" 2>/dev/null)"; then mode=644; fi
  atomic_write "$SSHD_CONFIG" "$mode" "$content"
}

write_hguard_ssh_socket_override() {
  local keep_old_port="${1:-false}"
  local listen_lines content ipv6_available="false"

  assert_managed_or_absent "$HGUARD_SSH_SOCKET_OVERRIDE"
  [ -e "${HGUARD_PROC_ROOT}/net/if_inet6" ] && ipv6_available="true"
  listen_lines="ListenStream=0.0.0.0:${SSH_PORT}"
  if [ "$ipv6_available" = "true" ]; then
    listen_lines="${listen_lines}
ListenStream=[::]:${SSH_PORT}"
  fi
  if [ "$keep_old_port" = "true" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    listen_lines="${listen_lines}
ListenStream=0.0.0.0:${ORIGINAL_SSH_PORT}"
    if [ "$ipv6_available" = "true" ]; then
      listen_lines="${listen_lines}
ListenStream=[::]:${ORIGINAL_SSH_PORT}"
    fi
  fi
  content="# Managed by Hguard ${HGUARD_VERSION}
[Socket]
ListenStream=
${listen_lines}
"
  atomic_write "$HGUARD_SSH_SOCKET_OVERRIDE" 644 "$content"
}

write_hguard_ssh_runtime_policy() {
  local keep_old_port="${1:-false}"
  local any_changed="false"

  write_hguard_sshd_config "$keep_old_port"
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  ensure_hguard_sshd_include_first
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  detect_ssh_runtime_mode
  if [ "$SSH_RUNTIME_MODE" = "socket" ]; then
    write_hguard_ssh_socket_override "$keep_old_port"
    [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  elif [ -f "$HGUARD_SSH_SOCKET_OVERRIDE" ] && head -n 1 "$HGUARD_SSH_SOCKET_OVERRIDE" | grep -Fq 'Managed by Hguard'; then
    rm -f "$HGUARD_SSH_SOCKET_OVERRIDE"
    any_changed="true"
  fi
  ATOMIC_WRITE_CHANGED="$any_changed"
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
  # ss only prints a Netid column when the query spans multiple socket
  # families (e.g. -ltnupH, -t and -u together); a single-family query like
  # -ltnpH does not, which shifts every later column left by one. Find the
  # State column (LISTEN) instead of assuming a fixed index, and read the
  # local address:port three columns after it (State, Recv-Q, Send-Q,
  # Local-Address:Port).
  awk -v wanted="$port" '
    {
      state_col = 0
      for (i = 1; i <= NF; i++) { if ($i == "LISTEN") { state_col = i; break } }
      if (state_col == 0) next
      address = $(state_col + 3)
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

interactive_terminal_available() {
  [ -t 0 ]
}

configure_ssh_safely() {
  local keep_old_port="$PORT_MIGRATION_REQUIRED"
  local answer=""
  local policy_changed

  write_hguard_ssh_runtime_policy "$keep_old_port"
  policy_changed="$ATOMIC_WRITE_CHANGED"
  verify_effective_sshd_config || error "Effective sshd configuration does not match the Hguard policy. SSH was not restarted."
  if [ "$policy_changed" = "true" ] || ! verify_ssh_listener "$SSH_PORT"; then
    apply_ssh_runtime || error "Failed to apply SSH configuration safely. Keep the current root session open."
  fi
  verify_ssh_listener "$SSH_PORT" || error "Target SSH port ${SSH_PORT} is not listening through sshd/systemd. Old UFW access was preserved."
  if [ "$keep_old_port" = "true" ]; then
    verify_ssh_listener "$ORIGINAL_SSH_PORT" || error "Old SSH port ${ORIGINAL_SSH_PORT} was not preserved during staging. Keep the current session open and inspect SSH manually."
  fi
  ufw_tcp_rule_exists "$SSH_PORT" || error "Target SSH port ${SSH_PORT}/tcp is not allowed by UFW."

  if [ "$PORT_MIGRATION_REQUIRED" != "true" ]; then
    rm -f "$HGUARD_PENDING_PORT_MARKER"
    return 0
  fi

  atomic_write "$HGUARD_PENDING_PORT_MARKER" 600 "target=${SSH_PORT}
old=${ORIGINAL_SSH_PORT}
"
  warn "New SSH port ${SSH_PORT} is listening locally. Old port ${ORIGINAL_SSH_PORT} remains listening and allowed until remote login is confirmed."
  local migration_resolved migration_display_ip migration_display_hint
  migration_resolved="$(resolve_display_ip)"
  migration_display_ip="$(printf '%s\n' "$migration_resolved" | head -n1)"
  migration_display_hint="$(printf '%s\n' "$migration_resolved" | tail -n +2)"
  printf '请在第二个终端测试：ssh -p %s %s@%s\n' "$SSH_PORT" "$NEW_USER" "$migration_display_ip"
  [ -z "$migration_display_hint" ] || printf '%b%s%b\n' "$YELLOW" "$migration_display_hint" "$NC"

  if interactive_terminal_available; then
    read -r -p "确认第二终端登录和 sudo 正常后输入 YES；其他输入保留旧端口：" answer
  fi
  if [ "$answer" != "YES" ]; then
    INSTALL_STATUS="pending-port-finalization"
    return 0
  fi

  write_hguard_ssh_runtime_policy false
  policy_changed="$ATOMIC_WRITE_CHANGED"
  verify_effective_sshd_config || error "Final SSH configuration validation failed; old UFW rule remains."
  if [ "$policy_changed" = "true" ] || ! verify_ssh_listener "$SSH_PORT"; then
    apply_ssh_runtime || error "Could not finalize the SSH runtime; old UFW rule remains."
  fi
  verify_ssh_listener "$SSH_PORT" || error "Target SSH listener disappeared during finalization; old UFW rule remains."

  if verify_ssh_listener "$ORIGINAL_SSH_PORT"; then
    warn "Old SSH port ${ORIGINAL_SSH_PORT} is still being listened on after finalization. Check for another 'Port' directive in sshd_config or a drop-in outside Hguard's management."
    INSTALL_STATUS="success-with-warnings"
  fi

  if grep -Fxq "${ORIGINAL_SSH_PORT}/tcp" "$HGUARD_MANAGED_RULES" 2>/dev/null; then
    ufw --force delete allow "${ORIGINAL_SSH_PORT}/tcp"
    remove_managed_rule_record "${ORIGINAL_SSH_PORT}/tcp"
  else
    warn "Old UFW rule ${ORIGINAL_SSH_PORT}/tcp predates Hguard and was preserved."
  fi
  rm -f "$HGUARD_PENDING_PORT_MARKER"
  PORT_MIGRATION_REQUIRED="false"
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

# A lightweight sanity check, not full RFC validation (matching
# is_private_ipv4's style) - just enough to refuse obviously-not-an-address
# input before it lands in a jail config.
looks_like_ip_address() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && return 0
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && return 0
  return 1
}

# The current SSH client's address, so it can be exempted from fail2ban -
# otherwise a client that retries several local keys before the right one
# can ban its own installer. SSH_CONNECTION (sshd sets it per-session) is
# tried first; `sudo -i` can clear it, so `who -m`'s "(address)" suffix for
# the current TTY is the fallback. Prints nothing and fails if neither
# yields something that looks like an address.
current_connection_ip() {
  local ip

  ip="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk 'NF >= 1 {print $1}')"
  if [ -z "$ip" ]; then
    ip="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\))[[:space:]]*$/\1/p' | head -n1)"
  fi
  looks_like_ip_address "$ip" || return 1
  printf '%s\n' "$ip"
}

configure_fail2ban() {
  local content protected_ports ignoreip
  assert_managed_or_absent "$FAIL2BAN_JAIL"
  protected_ports="$SSH_PORT"
  if [ -f "$HGUARD_PENDING_PORT_MARKER" ] && [ "$ORIGINAL_SSH_PORT" != "$SSH_PORT" ]; then
    protected_ports="${SSH_PORT},${ORIGINAL_SSH_PORT}"
  fi

  ignoreip="127.0.0.1/8 ::1"
  if INSTALLER_IP="$(current_connection_ip)"; then
    ignoreip="${ignoreip} ${INSTALLER_IP}"
  else
    INSTALLER_IP=""
    warn "无法确定当前连接的来源 IP（SSH_CONNECTION 为空，who -m 也没有给出可用地址）；未将任何地址加入 fail2ban 白名单。"
  fi

  content="# Managed by Hguard ${HGUARD_VERSION}
[sshd]
enabled = true
port = ${protected_ports}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
ignoreip = ${ignoreip}
"
  atomic_write "$FAIL2BAN_JAIL" 644 "$content"
  local jail_changed="$ATOMIC_WRITE_CHANGED"
  fail2ban-client -t >/dev/null 2>&1 || error "The fail2ban configuration test failed."

  local needs_restart="false"
  if [ "$jail_changed" = "true" ] || ! fail2ban-client status sshd >/dev/null 2>&1; then
    needs_restart="true"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable fail2ban.service
    systemctl is-active --quiet fail2ban.service || needs_restart="true"
    if [ "$needs_restart" = "true" ]; then
      systemctl restart fail2ban.service
    fi
    systemctl is-active --quiet fail2ban.service || error "fail2ban did not become active."
  elif [ "$needs_restart" = "true" ]; then
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
  local sysctl_changed

  assert_managed_or_absent "$BBR_SYSCTL_FILE"
  atomic_write "$BBR_SYSCTL_FILE" 644 "# Managed by Hguard ${HGUARD_VERSION}
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
"
  sysctl_changed="$ATOMIC_WRITE_CHANGED"

  if [ "$module_persistence" = "auto" ]; then
    if lsmod 2>/dev/null | awk '$1 == "tcp_bbr" {found=1} END {exit !found}'; then
      module_persistence="true"
    else
      module_persistence="false"
    fi
  fi
  if [ "$module_persistence" = "true" ] || [ "$module_persistence" = "1" ]; then
    assert_managed_or_absent "$BBR_MODULES_FILE"
    atomic_write "$BBR_MODULES_FILE" 644 "# Managed by Hguard ${HGUARD_VERSION}
tcp_bbr
"
  elif [ -f "$BBR_MODULES_FILE" ] && head -n 1 "$BBR_MODULES_FILE" | grep -Fq 'Managed by Hguard'; then
    rm -f "$BBR_MODULES_FILE"
  fi
  ATOMIC_WRITE_CHANGED="$sysctl_changed"
}

migrate_legacy_bbr_file() {
  local legacy_file="${HGUARD_ETC_ROOT}/sysctl.d/99-bbr.conf"
  local normalized

  [ -f "$legacy_file" ] || return 0
  normalized="$(awk 'NF && $1 !~ /^#/ {gsub(/[[:space:]]/, ""); print}' "$legacy_file")"
  if [ "$normalized" = $'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr' ]; then
    rm -f "$legacy_file"
    info "Removed the exact legacy Hguard BBR file after migrating to ${BBR_SYSCTL_FILE}."
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
  local sysctl_changed="$ATOMIC_WRITE_CHANGED"
  migrate_legacy_bbr_file
  if [ "$sysctl_changed" = "true" ] || [ "$current" != "bbr" ] || [ "$qdisc" != "fq" ]; then
    sysctl -p "$BBR_SYSCTL_FILE" >/dev/null 2>&1 || apply_failed="true"
  fi
  if ! current="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current=""; fi
  if ! qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then qdisc=""; fi
  BBR_STATUS="$(classify_bbr_state "$available" "$current" "$qdisc" "$apply_failed")"

  case "$BBR_STATUS" in
    enabled|already-enabled) info "BBR status: ${BBR_STATUS} (bbr + fq)." ;;
    failed) warn "BBR is supported but could not be applied; core SSH installation will continue." ;;
    unsupported) warn "BBR is unsupported; core SSH installation will continue." ;;
  esac
}

is_unsigned_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

read_first_line() {
  local file="$1"

  [ -r "$file" ] || return 1
  awk 'NF {print; exit}' "$file"
}

conntrack_count_file() {
  printf '%s/net/netfilter/nf_conntrack_count\n' "$HGUARD_PROC_SYS_ROOT"
}

conntrack_max_file() {
  printf '%s/net/netfilter/nf_conntrack_max\n' "$HGUARD_PROC_SYS_ROOT"
}

conntrack_timeout_file() {
  printf '%s/net/netfilter/nf_conntrack_tcp_timeout_%s\n' "$HGUARD_PROC_SYS_ROOT" "$1"
}

conntrack_hashsize_file() {
  printf '%s/nf_conntrack/parameters/hashsize\n' "$HGUARD_SYS_MODULE_ROOT"
}

conntrack_profile_syn_sent_target() {
  printf '30\n'
}

conntrack_profile_syn_recv_target() {
  printf '20\n'
}

conntrack_profile_time_wait_target() {
  printf '30\n'
}

conntrack_read_count() {
  read_first_line "$(conntrack_count_file)"
}

conntrack_read_max() {
  read_first_line "$(conntrack_max_file)"
}

conntrack_read_hashsize() {
  read_first_line "$(conntrack_hashsize_file)"
}

conntrack_usage_percent() {
  local count="$1"
  local maximum="$2"

  is_unsigned_integer "$count" || return 1
  is_unsigned_integer "$maximum" || return 1
  [ "$maximum" -gt 0 ] || return 1
  awk -v count="$count" -v maximum="$maximum" 'BEGIN {printf "%.1f", (count / maximum) * 100}'
}

conntrack_usage_tenths() {
  local count="$1"
  local maximum="$2"

  is_unsigned_integer "$count" || return 1
  is_unsigned_integer "$maximum" || return 1
  [ "$maximum" -gt 0 ] || return 1
  awk -v count="$count" -v maximum="$maximum" 'BEGIN {printf "%d", (count * 1000) / maximum}'
}

conntrack_table_full_state() {
  local logs="" command_output

  if [ -n "${HGUARD_CONNTRACK_LOG_TEXT+x}" ]; then
    logs="$HGUARD_CONNTRACK_LOG_TEXT"
  else
    if command -v dmesg >/dev/null 2>&1 && command_output="$(dmesg 2>/dev/null)"; then
      logs="${logs}${command_output}
"
    fi
    if command -v journalctl >/dev/null 2>&1 && command_output="$(journalctl -k -b --no-pager 2>/dev/null)"; then
      logs="${logs}${command_output}
"
    fi
  fi

  if printf '%s\n' "$logs" | grep -Fq 'nf_conntrack: table full, dropping packet'; then
    printf 'yes\n'
  elif [ -n "$logs" ] || [ -n "${HGUARD_CONNTRACK_LOG_TEXT+x}" ]; then
    printf 'no\n'
  else
    printf 'unknown\n'
  fi
}

classify_conntrack_health() {
  local count="$1"
  local maximum="$2"
  local table_full="$3"
  local usage_tenths

  [ "$table_full" = "yes" ] && { printf 'CRITICAL\n'; return 0; }
  if ! usage_tenths="$(conntrack_usage_tenths "$count" "$maximum")"; then
    printf 'UNAVAILABLE\n'
    return 0
  fi
  if [ "$usage_tenths" -ge 900 ]; then
    printf 'CRITICAL\n'
  elif [ "$usage_tenths" -ge 750 ]; then
    printf 'WARNING\n'
  elif [ "$usage_tenths" -ge 500 ]; then
    printf 'NOTICE\n'
  else
    printf 'OK\n'
  fi
}

conntrack_status_fields() {
  local count maximum hashsize usage table_full health

  if ! count="$(conntrack_read_count 2>/dev/null)"; then count="unavailable"; fi
  if ! maximum="$(conntrack_read_max 2>/dev/null)"; then maximum="unavailable"; fi
  if ! hashsize="$(conntrack_read_hashsize 2>/dev/null)"; then hashsize="unavailable"; fi
  if ! usage="$(conntrack_usage_percent "$count" "$maximum" 2>/dev/null)"; then usage="unavailable"; fi
  table_full="$(conntrack_table_full_state)"
  health="$(classify_conntrack_health "$count" "$maximum" "$table_full")"
  printf '%s|%s|%s|%s|%s|%s\n' "$count" "$maximum" "$usage" "$hashsize" "$table_full" "$health"
}

print_conntrack_install_check() {
  local fields count maximum usage hashsize table_full health

  fields="$(conntrack_status_fields)"
  IFS='|' read -r count maximum usage hashsize table_full health <<< "$fields"
  case "$health" in
    OK)
      ok "Conntrack usage: ${usage}% (${count} / ${maximum}); hash buckets: ${hashsize}."
      ;;
    NOTICE|WARNING|CRITICAL)
      warn "Conntrack health ${health}: ${usage}% (${count} / ${maximum}); table exhaustion evidence in accessible kernel logs: ${table_full}."
      if [ "$table_full" = "yes" ]; then
        warn "Conntrack table exhaustion was detected in accessible kernel logs; Linux has dropped packets before they reached applications."
      fi
      warn "No conntrack kernel parameter was changed. Run 'sudo bash install.sh --optimize-conntrack' only if you explicitly want Hguard to apply its conservative conntrack profile."
      ;;
    *)
      warn "Conntrack health is unavailable on this kernel/container; continuing without changing conntrack settings."
      ;;
  esac
}

system_ram_mb() {
  local meminfo="${HGUARD_PROC_ROOT}/meminfo"

  [ -r "$meminfo" ] || { printf 'unknown\n'; return 0; }
  awk '$1 == "MemTotal:" {printf "%d\n", $2 / 1024; found=1} END {if (!found) print "unknown"}' "$meminfo"
}

max_unsigned() {
  local current="$1"
  local floor="$2"

  if is_unsigned_integer "$current" && [ "$current" -gt "$floor" ]; then
    printf '%s\n' "$current"
  else
    printf '%s\n' "$floor"
  fi
}

min_timeout_target() {
  local current="$1"
  local recommended="$2"

  if is_unsigned_integer "$current" && [ "$current" -gt 0 ] && [ "$current" -lt "$recommended" ]; then
    printf '%s\n' "$current"
  else
    printf '%s\n' "$recommended"
  fi
}

conntrack_runtime_profile_state() {
  local maximum hashsize syn_sent syn_recv time_wait

  if ! maximum="$(conntrack_read_max 2>/dev/null)"; then
    printf 'unavailable\n'
    return 0
  fi
  if ! hashsize="$(conntrack_read_hashsize 2>/dev/null)"; then
    printf 'unavailable\n'
    return 0
  fi
  if ! syn_sent="$(read_first_line "$(conntrack_timeout_file syn_sent)" 2>/dev/null)"; then
    printf 'unavailable\n'
    return 0
  fi
  if ! syn_recv="$(read_first_line "$(conntrack_timeout_file syn_recv)" 2>/dev/null)"; then
    printf 'unavailable\n'
    return 0
  fi
  if ! time_wait="$(read_first_line "$(conntrack_timeout_file time_wait)" 2>/dev/null)"; then
    printf 'unavailable\n'
    return 0
  fi

  if ! is_unsigned_integer "$maximum" || [ "$maximum" -lt 65536 ]; then
    printf 'drift detected\n'
  elif ! is_unsigned_integer "$hashsize" || [ "$hashsize" -lt 16384 ]; then
    printf 'drift detected\n'
  elif [ "$syn_sent" != "$(conntrack_profile_syn_sent_target)" ]; then
    printf 'drift detected\n'
  elif [ "$syn_recv" != "$(conntrack_profile_syn_recv_target)" ]; then
    printf 'drift detected\n'
  elif [ "$time_wait" != "$(conntrack_profile_time_wait_target)" ]; then
    printf 'drift detected\n'
  else
    printf 'active\n'
  fi
}

foreign_conntrack_config_sources() {
  local file first_line
  local sources=""
  local pattern='net.netfilter.nf_conntrack_|options[[:space:]]+nf_conntrack[[:space:]].*hashsize|nf_conntrack[[:space:]].*hashsize'

  for file in "${HGUARD_ETC_ROOT}/sysctl.conf" "${HGUARD_ETC_ROOT}"/sysctl.d/*.conf "${HGUARD_ETC_ROOT}"/modprobe.d/*.conf; do
    [ -f "$file" ] || continue
    first_line="$(head -n 1 "$file" 2>/dev/null || printf '')"
    case "$file" in
      "$CONNTRACK_SYSCTL_FILE"|"$CONNTRACK_MODPROBE_FILE")
        printf '%s\n' "$first_line" | grep -Fq 'Managed by Hguard' && continue
        ;;
    esac
    if grep -Eq "$pattern" "$file"; then
      sources="${sources}${file}
"
    fi
  done
  printf '%s' "$sources" | awk 'NF && !seen[$0]++'
}

write_conntrack_helper_file() {
  local helper_content

  assert_managed_or_absent "$CONNTRACK_HELPER_FILE"
  helper_content="#!/usr/bin/env bash
# Managed by Hguard ${HGUARD_VERSION}; optional conntrack runtime floor.
set -euo pipefail

PROC_SYS_ROOT=\"\${HGUARD_PROC_SYS_ROOT:-/proc/sys}\"
MAX_FILE=\"\${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_max\"
SYN_SENT_FILE=\"\${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_syn_sent\"
SYN_RECV_FILE=\"\${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_syn_recv\"
TIME_WAIT_FILE=\"\${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_time_wait\"

read_uint() {
  local file=\"\$1\"
  [ -r \"\$file\" ] || return 1
  awk 'NF {print; exit}' \"\$file\" | grep -Eq '^[0-9]+$'
  awk 'NF {print; exit}' \"\$file\"
}

write_value() {
  local file=\"\$1\"
  local value=\"\$2\"
  [ -e \"\$file\" ] || return 0
  printf '%s\n' \"\$value\" > \"\$file\" 2>/dev/null || true
}

if current_max=\"\$(read_uint \"\$MAX_FILE\" 2>/dev/null)\" && [ \"\$current_max\" -lt 65536 ]; then
  write_value \"\$MAX_FILE\" 65536
fi
write_value \"\$SYN_SENT_FILE\" $(conntrack_profile_syn_sent_target)
write_value \"\$SYN_RECV_FILE\" $(conntrack_profile_syn_recv_target)
write_value \"\$TIME_WAIT_FILE\" $(conntrack_profile_time_wait_target)
"
  atomic_write "$CONNTRACK_HELPER_FILE" 755 "$helper_content"
}

write_conntrack_files() {
  local target_hashsize="$1"
  local sysctl_content modprobe_content modules_content service_content

  assert_managed_or_absent "$CONNTRACK_SYSCTL_FILE"
  assert_managed_or_absent "$CONNTRACK_MODPROBE_FILE"
  assert_managed_or_absent "$CONNTRACK_MODULES_FILE"
  assert_managed_or_absent "$CONNTRACK_SERVICE_FILE"
  sysctl_content="# Managed by Hguard ${HGUARD_VERSION}; optional conntrack timeout profile.
# nf_conntrack is loaded early through ${CONNTRACK_MODULES_FILE} so systemd-sysctl can see these keys.
# Netfilter conntrack timeouts; these are not TCP socket TIME_WAIT settings.
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = $(conntrack_profile_syn_sent_target)
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = $(conntrack_profile_syn_recv_target)
net.netfilter.nf_conntrack_tcp_timeout_time_wait = $(conntrack_profile_time_wait_target)
"
  modprobe_content="# Managed by Hguard ${HGUARD_VERSION}; applies when nf_conntrack is next loaded.
options nf_conntrack hashsize=${target_hashsize}
"
  modules_content="# Managed by Hguard ${HGUARD_VERSION}; load conntrack before systemd-sysctl.
nf_conntrack
"
  service_content="# Managed by Hguard ${HGUARD_VERSION}; optional conntrack runtime floor.
[Unit]
Description=Apply Hguard conntrack runtime profile
Documentation=https://github.com/hcloudlab/Hguard
DefaultDependencies=no
Wants=systemd-modules-load.service
After=systemd-modules-load.service systemd-sysctl.service
Before=network-pre.target ufw.service
ConditionPathExists=/proc/sys/net/netfilter/nf_conntrack_max

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash ${CONNTRACK_HELPER_FILE}

[Install]
WantedBy=sysinit.target
"
  local any_changed="false"
  atomic_write "$CONNTRACK_SYSCTL_FILE" 644 "$sysctl_content"
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  atomic_write "$CONNTRACK_MODPROBE_FILE" 644 "$modprobe_content"
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  atomic_write "$CONNTRACK_MODULES_FILE" 644 "$modules_content"
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  write_conntrack_helper_file
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  atomic_write "$CONNTRACK_SERVICE_FILE" 644 "$service_content"
  [ "$ATOMIC_WRITE_CHANGED" = "true" ] && any_changed="true"
  ATOMIC_WRITE_CHANGED="$any_changed"
}

apply_conntrack_runtime_values() {
  local target_hashsize="$1"
  local files_changed="${2:-true}"

  # The gate: when the managed files didn't change and the runtime profile
  # is already active (both folded into files_changed by the caller),
  # there is nothing to (re)apply - skip entirely instead of rewriting the
  # same hashsize value and logging "Updated"/"Applied" on every rerun.
  # The helper script covers max/timeouts; this is the only place that
  # applies the hashsize floor at runtime (hashsize has no sysctl key).
  [ "$files_changed" = "true" ] || return 0

  if [ "$HGUARD_TEST_MODE" = "1" ]; then
    HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE" || true
    [ ! -e "$(conntrack_hashsize_file)" ] || printf '%s\n' "$target_hashsize" > "$(conntrack_hashsize_file)" 2>/dev/null || true
    return 0
  fi

  if command -v modprobe >/dev/null 2>&1; then
    if ! modprobe nf_conntrack >/dev/null 2>&1; then
      warn "modprobe nf_conntrack failed; persistent module-load config was written for reboot."
    fi
  fi
  if ! bash "$CONNTRACK_HELPER_FILE"; then
    warn "Could not apply the conntrack runtime floor helper; persistent systemd unit was written for reboot."
  fi
  if ! sysctl -q -p "$CONNTRACK_SYSCTL_FILE" >/dev/null 2>&1; then
    warn "Could not apply conntrack timeout sysctl values at runtime; persistent config was written for reboot."
  fi
  if [ -w "$(conntrack_hashsize_file)" ]; then
    if printf '%s\n' "$target_hashsize" > "$(conntrack_hashsize_file)" 2>/dev/null; then
      info "Updated nf_conntrack hashsize at runtime."
    else
      warn "Could not update nf_conntrack hashsize at runtime; reboot to apply ${CONNTRACK_MODPROBE_FILE}."
    fi
  else
    warn "nf_conntrack hashsize cannot be changed at runtime here; reboot to apply ${CONNTRACK_MODPROBE_FILE}."
  fi
}

enable_conntrack_service() {
  if [ "$HGUARD_TEST_MODE" = "1" ]; then
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl is unavailable; conntrack runtime helper was written but cannot be enabled automatically."
    return 0
  fi
  systemctl daemon-reload || warn "systemctl daemon-reload failed after writing ${CONNTRACK_SERVICE_FILE}."
  systemctl enable "$CONNTRACK_SERVICE_NAME" >/dev/null 2>&1 \
    || warn "Could not enable ${CONNTRACK_SERVICE_NAME}; run status.sh after reboot to check for conntrack profile drift."
}

optimize_conntrack() {
  local current_hash
  local target_hash
  local foreign_sources foreign_count ram_mb

  if ! current_hash="$(conntrack_read_hashsize 2>/dev/null)"; then current_hash=""; fi
  ram_mb="$(system_ram_mb)"

  foreign_sources="$(foreign_conntrack_config_sources)"
  if [ -n "$foreign_sources" ]; then
    foreign_count="$(printf '%s\n' "$foreign_sources" | awk 'NF {count++} END {print count + 0}')"
    warn "Existing conntrack configuration detected outside Hguard:"
    printf '%s\n' "$foreign_sources" | sed 's/^/  - /'
    if [ "$foreign_count" -gt 1 ]; then
      warn "Multiple conntrack configuration sources detected."
    fi
    warn "No Hguard conntrack file was written; user-owned kernel configuration was preserved."
    return 0
  fi

  target_hash="$(max_unsigned "$current_hash" 16384)"

  write_conntrack_files "$target_hash"
  local conntrack_files_changed="$ATOMIC_WRITE_CHANGED"
  enable_conntrack_service
  if [ "$conntrack_files_changed" != "true" ] && [ "$(conntrack_runtime_profile_state)" != "active" ]; then
    conntrack_files_changed="true"
  fi
  apply_conntrack_runtime_values "$target_hash" "$conntrack_files_changed"
  if [ "$conntrack_files_changed" = "true" ]; then
    info "Applied Hguard conntrack profile: max floor=65536, hashsize floor=${target_hash}, syn_sent=$(conntrack_profile_syn_sent_target), syn_recv=$(conntrack_profile_syn_recv_target), time_wait=$(conntrack_profile_time_wait_target), RAM=${ram_mb}MB."
    warn "hashsize persistence depends on nf_conntrack reload/reboot; verify after reboot with status.sh."
  else
    info "Hguard conntrack profile already active; no changes needed (max floor=65536, hashsize floor=${target_hash})."
  fi
  print_conntrack_install_check
}

verify_authorized_keys() {
  local user_home ssh_directory authorized_keys owner ssh_owner ssh_mode key_mode

  user_home="$(managed_user_home)"
  ssh_directory="${user_home}/.ssh"
  authorized_keys="${ssh_directory}/authorized_keys"
  [ -s "$authorized_keys" ] || return 1
  if ! owner="$(stat -c '%U:%G' "$authorized_keys" 2>/dev/null)"; then owner=""; fi
  if ! ssh_owner="$(stat -c '%U:%G' "$ssh_directory" 2>/dev/null)"; then ssh_owner=""; fi
  if ! ssh_mode="$(stat -c '%a' "$ssh_directory" 2>/dev/null)"; then ssh_mode=""; fi
  if ! key_mode="$(stat -c '%a' "$authorized_keys" 2>/dev/null)"; then key_mode=""; fi
  [ "$owner" = "${NEW_USER}:${NEW_USER}" ] && [ "$ssh_owner" = "${NEW_USER}:${NEW_USER}" ] \
    && [ "$ssh_mode" = "700" ] && [ "$key_mode" = "600" ]
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
  if ! owner="$(stat -c '%U:%G' "$HGUARD_CONFIG_FILE" 2>/dev/null)"; then owner=""; fi
  if ! mode="$(stat -c '%a' "$HGUARD_CONFIG_FILE" 2>/dev/null)"; then mode=""; fi
  [ "$owner" = "root:root" ] && [ "$mode" = "600" ]
}

# Read-only: the actual acceptance checks, and nothing else. Used by
# run_final_acceptance (below) during install, and directly by `hguard
# verify` (bin/hguard-verify.sh) for a read-only recheck that must never
# write config/state - only this function's checks need to stay in sync
# between the two callers, not any side effect.
# Prints "<failures> <warnings>" on success (always "succeeds" itself;
# the caller decides what a nonzero failure count means).
run_acceptance_checks() {
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
  verify_config_permissions || { warn "Acceptance: Hguard config ownership or mode is invalid."; failures=$((failures + 1)); }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet fail2ban.service || { warn "Acceptance: fail2ban service is inactive."; failures=$((failures + 1)); }
  fi
  fail2ban-client status sshd >/dev/null 2>&1 || { warn "Acceptance: fail2ban sshd jail unavailable."; failures=$((failures + 1)); }

  if ! current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current_cc=""; fi
  if ! current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then current_qdisc=""; fi
  if [ "$current_cc" != "bbr" ] || [ "$current_qdisc" != "fq" ]; then
    warnings=$((warnings + 1))
  fi

  printf '%s %s\n' "$failures" "$warnings"
}

run_final_acceptance() {
  local failures warnings

  # run_acceptance_checks' warn() calls print to stdout too, ahead of its
  # final "<failures> <warnings>" line - take only the last line.
  read -r failures warnings <<< "$(run_acceptance_checks | tail -n1)"

  [ "$failures" -eq 0 ] || return 1
  if [ "$INSTALL_STATUS" = "pending-port-finalization" ]; then
    :
  elif [ "$warnings" -gt 0 ] || [ "$INSTALL_STATUS" = "success-with-warnings" ]; then
    INSTALL_STATUS="success-with-warnings"
  else
    INSTALL_STATUS="success"
  fi
  if [ -n "$PREVIOUS_MANAGED_USER" ] && [ "$PREVIOUS_MANAGED_USER" != "$NEW_USER" ]; then
    warn "Previous managed user ${PREVIOUS_MANAGED_USER} still exists and was not deleted. Review its access manually."
  fi
  write_config_env
  atomic_write "$HGUARD_INSTALLED_MARKER" 600 "${INSTALL_STATUS}
"
}

# RFC 1918 (10/8, 172.16/12, 192.168/16) plus RFC 6598 (100.64/10, the
# carrier-grade NAT range clouds like AWS/GCP use for the VPC-internal
# address handed back by `hostname -I`). No external network call is made
# to learn the public IP; we only decide whether to hide the private one.
is_private_ipv4() {
  local ip="$1" a b
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  a="${BASH_REMATCH[1]}"
  b="${BASH_REMATCH[2]}"
  case "$a" in
    10) return 0 ;;
    172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] ;;
    192) [ "$b" -eq 168 ] ;;
    100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] ;;
    *) return 1 ;;
  esac
}

# Resolves the IP to show the operator in an "ssh -p ... user@<ip>" hint.
# Prints the display value (a real address, or the SERVER_IP placeholder)
# on the first line; when hostname -I's address is private, also prints a
# hint (to be shown alongside, not parsed) on a second line explaining to
# use the provider console's public IP instead. Shared by the port-
# migration prompt and the final summary, so both show the same thing
# instead of one always falling back to a literal "SERVER_IP".
resolve_display_ip() {
  local detected_ip

  detected_ip="$(hostname -I | awk '{print $1}')"
  if [ -n "$detected_ip" ] && is_private_ipv4 "$detected_ip"; then
    printf 'SERVER_IP\n'
    printf '检测到的是云内网地址（%s），请替换上面的 SERVER_IP 为服务商控制台中的公网 IP。\n' "$detected_ip"
    return 0
  fi
  printf '%s\n' "${detected_ip:-SERVER_IP}"
}

# The five files that make up the hguard CLI once installed: this file
# itself (constants/functions/installer) plus its lib-mode sibling scripts.
hguard_cli_component_files() {
  printf 'install-core.sh\nstatus.sh\nuninstall.sh\nverify.sh\nupdate.sh\napt-hook.sh\n'
}

fetch_hguard_component() {
  local name="$1" destination="$2" url

  url="${HGUARD_RAW_BASE_URL}/v${HGUARD_VERSION}/${name}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    return 1
  fi
}

# Installs the hguard CLI: this file and its sibling scripts into
# HGUARD_LIB_DIR, and a small dispatcher at HGUARD_CLI_PATH. A one-click
# install only ever has install-core.sh on disk (install.sh downloaded just
# that one file); any sibling not found next to it is fetched from
# HGUARD_RAW_BASE_URL, the same way install.sh fetched install-core.sh
# itself. Best-effort: failure here must never fail the install that
# already succeeded.
install_hguard_cli() {
  local self_dir name source_path temp_download dispatcher_content

  if self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; then
    :
  else
    self_dir=""
  fi

  ensure_directory "$HGUARD_LIB_DIR" 755

  while IFS= read -r name; do
    temp_download=""
    if [ -n "$self_dir" ] && [ -f "${self_dir}/${name}" ]; then
      source_path="${self_dir}/${name}"
    else
      temp_download="$(mktemp)"
      if ! fetch_hguard_component "$name" "$temp_download"; then
        warn "Could not fetch ${name} for the hguard CLI; /usr/local/lib/hguard is incomplete."
        rm -f "$temp_download"
        return 1
      fi
      source_path="$temp_download"
    fi
    install -m 755 "$source_path" "${HGUARD_LIB_DIR}/${name}"
    [ -z "$temp_download" ] || rm -f "$temp_download"
  done < <(hguard_cli_component_files)

  dispatcher_content="#!/usr/bin/env bash
set -euo pipefail
# ${MANAGED_MARKER} ${HGUARD_VERSION}
HGUARD_LIB_DIR=\"${HGUARD_LIB_DIR}\"
case \"\${1:-}\" in
  status) shift; exec bash \"\${HGUARD_LIB_DIR}/status.sh\" \"\$@\" ;;
  verify) shift; exec bash \"\${HGUARD_LIB_DIR}/verify.sh\" \"\$@\" ;;
  update) shift; exec bash \"\${HGUARD_LIB_DIR}/update.sh\" \"\$@\" ;;
  uninstall) shift; exec bash \"\${HGUARD_LIB_DIR}/uninstall.sh\" \"\$@\" ;;
  version) printf 'Hguard %s\\n' \"${HGUARD_VERSION}\" ;;
  *) printf 'Usage: hguard {status|verify|update|uninstall|version}\\n' >&2; exit 1 ;;
esac
"
  assert_managed_or_absent "$HGUARD_CLI_PATH"
  atomic_write "$HGUARD_CLI_PATH" 755 "$dispatcher_content"
}

# Installs the apt Post-Invoke hook that runs apt-hook.sh (already placed
# in HGUARD_LIB_DIR by install_hguard_cli) after every apt invocation. The
# hook itself decides whether anything actually needs verifying (see
# apt-hook.sh / managed_package_version_snapshot) and always exits 0 - this
# function only ever writes the two static files that wire it up.
install_apt_hook() {
  local hook_content

  [ -d "$APT_CONF_DIR" ] || return 1
  hook_content="# ${MANAGED_MARKER} ${HGUARD_VERSION}
DPkg::Post-Invoke { \"${HGUARD_APT_HOOK_SCRIPT} || true\"; };
"
  assert_managed_or_absent "$HGUARD_APT_HOOK_FILE"
  atomic_write "$HGUARD_APT_HOOK_FILE" 644 "$hook_content"
}

print_final_summary() {
  local resolved display_ip display_hint
  resolved="$(resolve_display_ip)"
  display_ip="$(printf '%s\n' "$resolved" | head -n1)"
  display_hint="$(printf '%s\n' "$resolved" | tail -n +2)"

  printf '\n%bHguard %s acceptance completed%b\n' "$BOLD" "$HGUARD_VERSION" "$NC"
  printf 'Install status: %s\n' "$INSTALL_STATUS"
  printf 'Managed user: %s\n' "$NEW_USER"
  printf 'Sudo mode: %s\n' "$SUDO_MODE"
  printf 'Target SSH port: %s\n' "$SSH_PORT"
  printf 'SSH runtime mode: %s\n' "$SSH_RUNTIME_MODE"
  printf 'BBR status: %s\n' "$BBR_STATUS"
  printf 'Test from a second terminal: ssh -p %s %s@%s\n' "$SSH_PORT" "$NEW_USER" "$display_ip"
  [ -z "$display_hint" ] || printf '%b%s%b\n' "$YELLOW" "$display_hint" "$NC"
  printf '%bDo not close the current session until remote login and sudo are verified.%b\n' "$YELLOW" "$NC"
  if [ "$INSTALL_STATUS" = "pending-port-finalization" ]; then
    warn "Old SSH port ${ORIGINAL_SSH_PORT} is intentionally retained. Rerun Hguard after remote validation to finalize."
  fi
  if [ -f "${HGUARD_RUN_ROOT}/reboot-required" ]; then
    warn "系统更新需要重启才能完全生效，确认新管理员登录正常后再手动重启。"
  fi
  if [ -n "$INSTALLER_IP" ]; then
    printf '已将当前连接 IP %s 加入 fail2ban 白名单；如果你的出口 IP 会变化（例如使用代理），换 IP 后多次登录失败仍可能被封禁。\n' "$INSTALLER_IP"
  fi
}

remove_legacy_phase_markers() {
  rm -f "${HGUARD_STATE_DIR}/.ssh_done" "${HGUARD_STATE_DIR}/.sudo_done" "${HGUARD_STATE_DIR}/.ufw_done"
}

# ---- VPSGuard -> Hguard migration (2.2) ----
#
# Trigger: a VPSGuard install exists (its state dir is present) and no
# Hguard state dir exists yet. Runs once, early in main() - after
# require_root/check_ubuntu_lts, before resolve_managed_user and anything
# else that reads HGUARD_CONFIG_FILE - so the rest of main() finds a
# config already in place and proceeds exactly like an ordinary rerun.
#
# Every subsystem below follows the same shape: write the new file(s),
# validate with the real tool for that subsystem (sshd -t, fail2ban-client
# -t, visudo -c, sysctl -p, systemctl is-enabled), only then remove the
# old file(s), and validate again. Nothing old is removed before its
# replacement is positively confirmed working; a failure at any point
# leaves the old (still-governing) configuration in place and errors out
# rather than guessing at a recovery.
migrate_from_vpsguard_needed() {
  # Not "no $HGUARD_STATE_DIR yet": migrate_vpsguard_copy_state_files
  # creates that directory as its first step, so checking its existence
  # would make this return false after a migration that got partway
  # through and failed - permanently stranding the system half-migrated,
  # since a rerun would then never retry. VPSGUARD_MIGRATED_MARKER_FILE is
  # written only once every step below has actually succeeded, so it is
  # the only correct "fully done" signal; each step function below is
  # itself safe to retry (every one starts by checking its own legacy
  # source still exists).
  [ -d "$VPSGUARD_LEGACY_STATE_DIR" ] && [ ! -f "$VPSGUARD_MIGRATED_MARKER_FILE" ]
}

migrate_vpsguard_copy_state_files() {
  local src dest name

  ensure_directory "$HGUARD_STATE_DIR" 700
  for name in config.env state.env managed-rules .installed .pending-port-finalization \
    .ssh_done .sudo_done .ufw_done; do
    src="${VPSGUARD_LEGACY_STATE_DIR}/${name}"
    [ -f "$src" ] || continue
    dest="${HGUARD_STATE_DIR}/${name}"
    cp -p "$src" "$dest" || error "Migration: could not copy ${src} to ${dest}."
    chmod 600 "$dest"
  done
}

# Mirrors ensure_hguard_sshd_include_first's removal half, but for the
# legacy markers: strips the VPSGuard include block out of SSHD_CONFIG,
# leaving everything else (including the already-inserted Hguard block)
# untouched.
migrate_remove_vpsguard_sshd_include() {
  local begin_count end_count content mode temporary_file

  if ! begin_count="$(grep -Fxc "$VPSGUARD_LEGACY_SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"; then begin_count=0; fi
  if ! end_count="$(grep -Fxc "$VPSGUARD_LEGACY_SSHD_INCLUDE_END" "$SSHD_CONFIG")"; then end_count=0; fi
  [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ] && return 0
  [ "$begin_count" -eq 1 ] && [ "$end_count" -eq 1 ] || return 1

  content="$(awk -v begin="$VPSGUARD_LEGACY_SSHD_INCLUDE_BEGIN" -v end="$VPSGUARD_LEGACY_SSHD_INCLUDE_END" '
    $0 == begin {inside=1; next}
    $0 == end {inside=0; next}
    !inside {print}
  ' "$SSHD_CONFIG")"
  if ! mode="$(stat -c '%a' "$SSHD_CONFIG" 2>/dev/null)"; then mode=644; fi
  temporary_file="$(mktemp "${SSHD_CONFIG}.vpsguard-migrate.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$temporary_file"
  chmod "$mode" "$temporary_file"
  mv -f "$temporary_file" "$SSHD_CONFIG"
}

migrate_vpsguard_sshd() {
  local ssh_port original_port keep_old_port backup

  [ -f "$SSHD_CONFIG" ] || return 0
  grep -Fxq "$VPSGUARD_LEGACY_SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG" 2>/dev/null || return 0

  if ! ssh_port="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)" || [ -z "$ssh_port" ]; then
    warn "Migration: could not determine the configured SSH port from the migrated config; sshd migration skipped, the VPSGuard config is preserved."
    return 1
  fi
  if ! original_port="$(read_env_value "$HGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)" || [ -z "$original_port" ]; then
    original_port="$ssh_port"
  fi
  SSH_PORT="$ssh_port"
  ORIGINAL_SSH_PORT="$original_port"
  keep_old_port="false"
  [ -f "$HGUARD_PENDING_PORT_MARKER" ] && [ "$original_port" != "$ssh_port" ] && keep_old_port="true"

  backup="$(mktemp "${SSHD_CONFIG}.vpsguard-migrate.XXXXXX")" || return 1
  cp -p "$SSHD_CONFIG" "$backup" || { rm -f "$backup"; return 1; }

  if ! write_hguard_sshd_config "$keep_old_port" || ! ensure_hguard_sshd_include_first; then
    rm -f "$HGUARD_SSHD_CONFIG"
    mv -f "$backup" "$SSHD_CONFIG"
    warn "Migration: could not write the new sshd drop-in/include; the VPSGuard config is preserved."
    return 1
  fi

  if ! sshd -t; then
    rm -f "$HGUARD_SSHD_CONFIG"
    mv -f "$backup" "$SSHD_CONFIG"
    warn "Migration: new sshd config failed validation (with the old config still also present); the VPSGuard config is preserved."
    return 1
  fi

  # Both the old and new include blocks/drop-ins are present and sshd -t
  # already passed with both. Remove only the old one, then validate again
  # before reloading - reload never runs against an unvalidated config.
  if ! migrate_remove_vpsguard_sshd_include; then
    warn "Migration: left the old VPSGuard sshd include in place (could not safely remove it); the new Hguard config is also active. Harmless - at most one orphan Include line."
  else
    rm -f "$VPSGUARD_LEGACY_SSHD_CONFIG"
    if ! sshd -t; then
      error "Migration: sshd config failed validation after removing the old VPSGuard include. Keep this session open; inspect ${SSHD_CONFIG} manually."
    fi
  fi

  if [ -f "$VPSGUARD_LEGACY_SSH_SOCKET_OVERRIDE" ]; then
    write_hguard_ssh_socket_override "$keep_old_port"
    rm -f "$VPSGUARD_LEGACY_SSH_SOCKET_OVERRIDE"
  fi

  apply_ssh_runtime || error "Migration: could not reload SSH after migrating its configuration. Keep this session open and investigate."
  verify_ssh_listener "$SSH_PORT" || error "Migration: SSH did not come back up on the configured port after reload. Keep this session open."
  rm -f "$backup"
}

migrate_vpsguard_fail2ban() {
  [ -f "$VPSGUARD_LEGACY_FAIL2BAN_JAIL" ] || return 0
  cp -p "$VPSGUARD_LEGACY_FAIL2BAN_JAIL" "$FAIL2BAN_JAIL"
  if ! fail2ban-client -t >/dev/null 2>&1; then
    rm -f "$FAIL2BAN_JAIL"
    warn "Migration: new fail2ban jail failed validation; the VPSGuard jail is preserved."
    return 1
  fi
  rm -f "$VPSGUARD_LEGACY_FAIL2BAN_JAIL"
  if ! fail2ban-client -t >/dev/null 2>&1; then
    error "Migration: fail2ban configuration failed validation after removing the old VPSGuard jail. Inspect ${HGUARD_ETC_ROOT}/fail2ban manually."
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban.service; then
    systemctl reload fail2ban.service || systemctl restart fail2ban.service
  fi
}

migrate_vpsguard_sudoers() {
  local new_user legacy_file new_file legacy_legacy_file

  if ! new_user="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)" || [ -z "$new_user" ]; then
    return 0
  fi
  legacy_file="${SUDOERS_DIR}/vpsguard-${new_user}"
  legacy_legacy_file="${SUDOERS_DIR}/90-vpsguard-${new_user}"
  # Not sudoers_file_for_user(): that reads the global $NEW_USER, which
  # resolve_managed_user hasn't set yet at migration time (migration runs
  # before it) - using it here would silently compute the wrong path
  # (missing the username entirely) and leave the migrated sudo grant
  # orphaned under a filename Hguard's own status/uninstall logic never
  # looks for.
  new_file="${SUDOERS_DIR}/hguard-${new_user}"

  if [ -f "$legacy_file" ]; then
    cp -p "$legacy_file" "$new_file"
    chmod 440 "$new_file"
    if ! visudo -cf "$new_file" >/dev/null 2>&1; then
      rm -f "$new_file"
      warn "Migration: new sudoers file failed validation; the VPSGuard sudoers file is preserved."
      return 1
    fi
    rm -f "$legacy_file"
    if ! visudo -c >/dev/null 2>&1; then
      error "Migration: global sudoers validation failed after removing the old VPSGuard sudoers file. Inspect ${SUDOERS_DIR} manually."
    fi
  fi
  # 90-vpsguard-<user> is already two generations obsolete by the time of
  # this migration; just retire it once the current generation (above, if
  # any) has been safely handled - no new file corresponds to it.
  if [ -f "$legacy_legacy_file" ] && managed_file_is_owned "$legacy_legacy_file"; then
    rm -f "$legacy_legacy_file"
  fi
}

migrate_vpsguard_bbr_and_conntrack_files() {
  local pairs old new target_hash

  pairs="${VPSGUARD_LEGACY_BBR_SYSCTL_FILE}:${BBR_SYSCTL_FILE}
${VPSGUARD_LEGACY_BBR_MODULES_FILE}:${BBR_MODULES_FILE}
${VPSGUARD_LEGACY_CONNTRACK_MODULES_FILE}:${CONNTRACK_MODULES_FILE}"
  while IFS=: read -r old new; do
    [ -n "$old" ] || continue
    [ -f "$old" ] || continue
    cp -p "$old" "$new"
    rm -f "$old"
  done <<< "$pairs"

  if [ -f "$VPSGUARD_LEGACY_CONNTRACK_SYSCTL_FILE" ]; then
    cp -p "$VPSGUARD_LEGACY_CONNTRACK_SYSCTL_FILE" "$CONNTRACK_SYSCTL_FILE"
    if ! sysctl -q -p "$CONNTRACK_SYSCTL_FILE" >/dev/null 2>&1; then
      warn "Migration: could not apply the migrated conntrack sysctl file at runtime; it is still installed for next boot."
    fi
    rm -f "$VPSGUARD_LEGACY_CONNTRACK_SYSCTL_FILE"
  fi

  if [ -f "$VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE" ]; then
    target_hash="$(awk -F= '/hashsize=/{print $2; exit}' "$VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE" 2>/dev/null)"
    cp -p "$VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODPROBE_FILE"
    rm -f "$VPSGUARD_LEGACY_CONNTRACK_MODPROBE_FILE"
    if [ -n "$target_hash" ] && [ -w "$(conntrack_hashsize_file)" ]; then
      printf '%s\n' "$target_hash" > "$(conntrack_hashsize_file)" 2>/dev/null || true
    fi
  fi

  if [ -f "$VPSGUARD_LEGACY_CONNTRACK_HELPER_FILE" ]; then
    cp -p "$VPSGUARD_LEGACY_CONNTRACK_HELPER_FILE" "$CONNTRACK_HELPER_FILE"
    chmod 755 "$CONNTRACK_HELPER_FILE"
    rm -f "$VPSGUARD_LEGACY_CONNTRACK_HELPER_FILE"
  fi
}

migrate_vpsguard_conntrack_service() {
  [ -f "$VPSGUARD_LEGACY_CONNTRACK_SERVICE_FILE" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  cp -p "$VPSGUARD_LEGACY_CONNTRACK_SERVICE_FILE" "$CONNTRACK_SERVICE_FILE"
  systemctl daemon-reload
  if ! systemctl enable "$CONNTRACK_SERVICE_NAME" >/dev/null 2>&1; then
    rm -f "$CONNTRACK_SERVICE_FILE"
    systemctl daemon-reload
    warn "Migration: could not enable ${CONNTRACK_SERVICE_NAME}; the old VPSGuard unit is left stopped/disabled below regardless, run --optimize-conntrack to redeploy."
  fi
  # Stop/disable the old unit only now that the new one is confirmed
  # enabled (or we gave up on it above) - never disable the old one first.
  systemctl stop "$VPSGUARD_LEGACY_CONNTRACK_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$VPSGUARD_LEGACY_CONNTRACK_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$VPSGUARD_LEGACY_CONNTRACK_SERVICE_FILE"
  systemctl daemon-reload
}

migrate_from_vpsguard() {
  migrate_from_vpsguard_needed || return 0

  info "检测到 VPSGuard 安装，正在迁移到 Hguard..."
  migrate_vpsguard_copy_state_files

  # Each of these already warns and safely rolls back its own subsystem
  # on failure (old VPSGuard config/file left fully in charge) - but under
  # set -e, calling a function that returns nonzero as a bare statement
  # aborts this whole script right there, with the MIGRATED marker never
  # written and no further steps run. Checking explicitly instead lets a
  # single subsystem's failure stop *migration* (rerun to retry - see
  # migrate_from_vpsguard_needed) without killing the rest of main()'s
  # install flow, which must still run against whatever did or didn't
  # finish migrating.
  if ! migrate_vpsguard_sshd; then
    warn "VPSGuard 迁移未完成（sshd 部分失败，已保留原有配置）；重新运行安装器可重试迁移。"
    return 1
  fi
  if ! migrate_vpsguard_fail2ban; then
    warn "VPSGuard 迁移未完成（fail2ban 部分失败，已保留原有配置）；重新运行安装器可重试迁移。"
    return 1
  fi
  if ! migrate_vpsguard_sudoers; then
    warn "VPSGuard 迁移未完成（sudoers 部分失败，已保留原有配置）；重新运行安装器可重试迁移。"
    return 1
  fi
  migrate_vpsguard_bbr_and_conntrack_files
  migrate_vpsguard_conntrack_service

  atomic_write "$VPSGUARD_MIGRATED_MARKER_FILE" 600 "Migrated to Hguard ${HGUARD_VERSION} at $(date -u '+%Y-%m-%dT%H:%M:%SZ').
This directory is left in place as a backup only and is no longer used by Hguard.
"
  info "VPSGuard 迁移完成；/etc/vpsguard 已保留作为备份，不再被使用。"
}

main() {
  parse_args "$@"
  require_root
  check_ubuntu_lts
  if [ "$OPTIMIZE_CONNTRACK" = "true" ]; then
    ensure_directory "$HGUARD_STATE_DIR" 700
    record_preinstall_state
    optimize_conntrack
    return 0
  fi
  # An incomplete migration (already warned about internally) must not
  # abort the rest of main() via set -e - the normal install flow below
  # still needs to run against whatever state resulted.
  migrate_from_vpsguard || true
  ensure_directory "$HGUARD_STATE_DIR" 700
  prepare_sshd_runtime_directory
  resolve_managed_user
  resolve_sudo_mode
  resolve_ssh_ports
  check_root_ssh_key
  check_sudo_mode_compatibility
  INSTALL_STATUS="failed"
  # Until the requested sudo transition is fully verified, keep the last
  # effective mode in persistent state so failed reruns report truthfully.
  write_pending_config_env
  record_preinstall_state
  upgrade_system
  # An OpenSSH package upgrade can remove /run/sshd while restarting the
  # socket-activated service. Recreate it before any post-upgrade sshd check.
  prepare_sshd_runtime_directory
  fail2ban_systemd_backend_available \
    || error "Fail2ban systemd backend dependency is unavailable after package installation. SSH hardening was not started."

  ensure_managed_user
  configure_authorized_keys
  configure_sudo
  verify_sudo_configuration || error "Sudo validation failed. SSH hardening was not started."
  write_config_env

  configure_ufw_before_ssh
  configure_ssh_safely
  configure_fail2ban
  enable_bbr
  optimize_conntrack

  run_final_acceptance || error "Final acceptance failed. The installed marker was not written; keep the current SSH session open."
  remove_legacy_phase_markers
  if install_hguard_cli; then
    install_apt_hook || warn "Could not install the apt verification hook (${HGUARD_APT_HOOK_FILE}); the hguard CLI is still usable."
  else
    warn "Could not install the hguard CLI (${HGUARD_CLI_PATH}); core hardening succeeded regardless."
  fi
  print_final_summary
}

if [ "$HGUARD_TEST_MODE" != "1" ] && [ "$HGUARD_LIB_MODE" != "1" ]; then
  main "$@"
fi
