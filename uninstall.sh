#!/usr/bin/env bash
set -euo pipefail

VPSGUARD_VERSION="0.3.5"
VPSGUARD_TEST_MODE="${VPSGUARD_TEST_MODE:-0}"
VPSGUARD_ETC_ROOT="${VPSGUARD_ETC_ROOT:-/etc}"
VPSGUARD_STATE_DIR="${VPSGUARD_STATE_DIR:-${VPSGUARD_ETC_ROOT}/vpsguard}"
VPSGUARD_CONFIG_FILE="${VPSGUARD_CONFIG_FILE:-${VPSGUARD_STATE_DIR}/config.env}"
VPSGUARD_STATE_FILE="${VPSGUARD_STATE_FILE:-${VPSGUARD_STATE_DIR}/state.env}"
VPSGUARD_MANAGED_RULES="${VPSGUARD_MANAGED_RULES:-${VPSGUARD_STATE_DIR}/managed-rules}"
VPSGUARD_INSTALLED_MARKER="${VPSGUARD_INSTALLED_MARKER:-${VPSGUARD_STATE_DIR}/.installed}"
VPSGUARD_PENDING_PORT_MARKER="${VPSGUARD_PENDING_PORT_MARKER:-${VPSGUARD_STATE_DIR}/.pending-port-finalization}"
VPSGUARD_SSHD_CONFIG="${VPSGUARD_SSHD_CONFIG:-${VPSGUARD_ETC_ROOT}/ssh/sshd_config.d/00-vpsguard.conf}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-${VPSGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local}"
SUDOERS_DIR="${SUDOERS_DIR:-${VPSGUARD_ETC_ROOT}/sudoers.d}"
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-${VPSGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf}"
BBR_MODULES_FILE="${BBR_MODULES_FILE:-${VPSGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf}"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BOLD="\033[1m"
NC="\033[0m"

info() {
  printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$1"
}

warn() {
  printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"
}

error() {
  printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$1" >&2
  exit 1
}

read_env_value() {
  local file="$1"
  local key="$2"
  local value

  [ -f "$file" ] || return 1
  value="$(awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file")"
  [ -n "$value" ] || return 1
  case "$value" in
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

managed_file_is_owned() {
  local file="$1"
  [ -f "$file" ] && head -n 1 "$file" | grep -Fq 'Managed by VPSGuard'
}

ufw_rule_exists_from_text() {
  local port="$1"
  awk -v target="${port}/tcp" '$1 == target {found=1} END {exit !found}'
}

ufw_tcp_rule_exists() {
  local port="$1"
  ufw status 2>/dev/null | ufw_rule_exists_from_text "$port"
}

unit_exists() {
  local unit="$1"
  systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk -v wanted="$unit" '$1 == wanted {found=1} END {exit !found}'
}

apply_ssh_runtime() {
  local service_unit="ssh.service"

  if ! command -v systemctl >/dev/null 2>&1; then
    service ssh reload || service sshd reload
    return
  fi

  if unit_exists sshd.service && ! unit_exists ssh.service; then
    service_unit="sshd.service"
  fi
  if unit_exists ssh.socket && { systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; }; then
    systemctl daemon-reload
    systemctl restart ssh.socket
    if systemctl is-active --quiet "$service_unit"; then
      systemctl reload "$service_unit" || systemctl restart "$service_unit"
    fi
  elif systemctl is-active --quiet "$service_unit"; then
    systemctl reload "$service_unit" || systemctl restart "$service_unit"
  else
    systemctl start "$service_unit"
  fi
}

remove_owned_file() {
  local file="$1"
  if managed_file_is_owned "$file"; then
    rm -f "$file"
    info "Removed VPSGuard-managed file: ${file}"
  elif [ -e "$file" ]; then
    warn "Preserved unrecognized file: ${file}"
  fi
}

remove_safe_ufw_rules() {
  local target_port="$1"
  local rule port

  [ -f "$VPSGUARD_MANAGED_RULES" ] || return 0
  if [ -f "$VPSGUARD_PENDING_PORT_MARKER" ]; then
    warn "Port finalization is pending; all recorded SSH rules are preserved to avoid lockout."
    return 0
  fi

  while IFS= read -r rule; do
    case "$rule" in
      ''|'#'*) continue ;;
    esac
    port="${rule%/tcp}"
    if [ "$port" = "$target_port" ]; then
      warn "Preserved current SSH rule ${rule}; removing it could lock out the administrator."
      continue
    fi
    if ufw_tcp_rule_exists "$port"; then
      ufw --force delete allow "$rule"
      info "Removed recorded VPSGuard UFW rule ${rule}."
    fi
  done < "$VPSGUARD_MANAGED_RULES"
}

remove_fail2ban_jail_safely() {
  remove_owned_file "$FAIL2BAN_JAIL"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban.service; then
    systemctl reload fail2ban.service || systemctl restart fail2ban.service
  elif command -v service >/dev/null 2>&1; then
    if ! service fail2ban reload >/dev/null 2>&1; then
      warn "fail2ban is not running through the legacy service manager; no global state was changed."
    fi
  fi
  info "fail2ban service enablement and unrelated jails were preserved."
}

remove_ssh_snippet_safely() {
  local target_port="$1"
  local original_port="$2"
  local backup

  [ -e "$VPSGUARD_SSHD_CONFIG" ] || return 0
  if ! managed_file_is_owned "$VPSGUARD_SSHD_CONFIG"; then
    warn "SSH snippet is not recognizable as VPSGuard-managed; preserving it."
    return 1
  fi
  if [ "$target_port" != "$original_port" ] || [ -f "$VPSGUARD_PENDING_PORT_MARKER" ]; then
    warn "VPSGuard SSH snippet was preserved because removing a changed/pending port remotely could cause lockout."
    return 1
  fi

  backup="$(mktemp "${VPSGUARD_SSHD_CONFIG}.uninstall.XXXXXX")"
  cp "$VPSGUARD_SSHD_CONFIG" "$backup"
  rm -f "$VPSGUARD_SSHD_CONFIG"
  if sshd -t && apply_ssh_runtime; then
    rm -f "$backup"
    info "Removed VPSGuard SSH snippet after syntax and runtime validation."
    return 0
  fi

  mv -f "$backup" "$VPSGUARD_SSHD_CONFIG"
  if ! apply_ssh_runtime; then
    warn "The SSH snippet was restored, but runtime re-application also failed. Keep the current session open and inspect SSH manually."
  fi
  warn "SSH restoration could not be validated; the VPSGuard snippet was restored."
  return 1
}

sudo_policy_has_full_admin_from_text() {
  awk '
    /^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+ALL[[:space:]]*$/ {found=1}
    END {exit !found}
  '
}

remove_legacy_sudoers_safely() {
  local managed_user="$1"
  local sudoers_file backup password_state policy_output

  sudoers_file="${SUDOERS_DIR}/90-vpsguard-${managed_user}"
  [ -e "$sudoers_file" ] || return 0
  if ! managed_file_is_owned "$sudoers_file"; then
    warn "Preserved unrecognized sudoers file: ${sudoers_file}"
    return 1
  fi
  if ! id -nG "$managed_user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then
    warn "Preserved legacy sudoers override because ${managed_user} is not in the sudo group."
    return 1
  fi
  if ! password_state="$(passwd -S "$managed_user" 2>/dev/null | awk '{print $2}')"; then
    password_state="unknown"
  fi
  if [ "$password_state" != "P" ]; then
    warn "Preserved legacy sudoers override because ${managed_user} has no usable sudo password."
    return 1
  fi

  backup="$(mktemp "${sudoers_file}.uninstall.XXXXXX")"
  cp "$sudoers_file" "$backup"
  rm -f "$sudoers_file"
  if visudo -c >/dev/null 2>&1 \
    && policy_output="$(LC_ALL=C sudo -l -U "$managed_user" 2>/dev/null)" \
    && printf '%s\n' "$policy_output" | sudo_policy_has_full_admin_from_text; then
    if ! sudo -u "$managed_user" sudo -k >/dev/null 2>&1; then
      warn "Could not clear the sudo credential cache while removing the legacy override."
    fi
    if ! sudo -u "$managed_user" sudo -n true >/dev/null 2>&1; then
      rm -f "$backup"
      info "Removed legacy VPSGuard passwordless sudo override; standard password-authenticated sudo remains available."
      return 0
    fi
  fi

  mv -f "$backup" "$sudoers_file"
  warn "Could not prove safe standard sudo access; restored ${sudoers_file}."
  return 1
}

main() {
  local managed_user target_port original_port confirmation ssh_removed="true"
  local leftovers="false"

  [ "$(id -u)" -eq 0 ] || error "Please run uninstall.sh as root."
  if ! managed_user="$(read_env_value "$VPSGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then managed_user=""; fi
  if ! target_port="$(read_env_value "$VPSGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)"; then target_port=""; fi
  if ! original_port="$(read_env_value "$VPSGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)"; then original_port=""; fi
  [ -n "$managed_user" ] || error "VPSGuard config is missing or invalid; refusing an untracked uninstall."

  printf '\n%bVPSGuard %s safe uninstall%b\n' "$BOLD" "$VPSGUARD_VERSION" "$NC"
  warn "The administrator account, home directory and authorized_keys will NOT be deleted."
  warn "UFW and fail2ban will NOT be globally disabled or reset."
  warn "The current SSH-port rule may be retained to prevent remote lockout."
  read -r -p "输入 UNINSTALL 继续：" confirmation
  [ "$confirmation" = "UNINSTALL" ] || { printf 'Cancelled.\n'; exit 0; }

  remove_safe_ufw_rules "$target_port"
  remove_fail2ban_jail_safely
  if ! remove_ssh_snippet_safely "$target_port" "$original_port"; then
    ssh_removed="false"
    leftovers="true"
  fi

  remove_owned_file "$BBR_SYSCTL_FILE"
  remove_owned_file "$BBR_MODULES_FILE"
  warn "Current kernel congestion-control state was not forced to another algorithm and no reboot was performed."

  if ! remove_legacy_sudoers_safely "$managed_user"; then
    leftovers="true"
  fi
  info "Administrator account ${managed_user} and all user files were preserved."

  rm -f "$VPSGUARD_INSTALLED_MARKER"
  if [ "$ssh_removed" = "true" ] && [ "$leftovers" = "false" ]; then
    rm -f "$VPSGUARD_PENDING_PORT_MARKER" "$VPSGUARD_MANAGED_RULES" "$VPSGUARD_CONFIG_FILE" "$VPSGUARD_STATE_FILE" \
      "${VPSGUARD_STATE_DIR}/.ssh_done" "${VPSGUARD_STATE_DIR}/.sudo_done" "${VPSGUARD_STATE_DIR}/.ufw_done"
    if ! rmdir "$VPSGUARD_STATE_DIR" 2>/dev/null; then
      warn "State directory was not empty and was preserved: ${VPSGUARD_STATE_DIR}"
    fi
    info "Safe uninstall completed."
  else
    warn "Uninstall completed partially. State was retained because SSH safety prevented full removal."
  fi
}

if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
