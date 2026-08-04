#!/usr/bin/env bash
set -euo pipefail

VPSGUARD_VERSION="0.3.5"
VPSGUARD_TEST_MODE="${VPSGUARD_TEST_MODE:-0}"
VPSGUARD_ETC_ROOT="${VPSGUARD_ETC_ROOT:-/etc}"
VPSGUARD_STATE_DIR="${VPSGUARD_STATE_DIR:-${VPSGUARD_ETC_ROOT}/vpsguard}"
VPSGUARD_CONFIG_FILE="${VPSGUARD_CONFIG_FILE:-${VPSGUARD_STATE_DIR}/config.env}"
VPSGUARD_STATE_FILE="${VPSGUARD_STATE_FILE:-${VPSGUARD_STATE_DIR}/state.env}"
VPSGUARD_INSTALLED_MARKER="${VPSGUARD_INSTALLED_MARKER:-${VPSGUARD_STATE_DIR}/.installed}"
VPSGUARD_PENDING_PORT_MARKER="${VPSGUARD_PENDING_PORT_MARKER:-${VPSGUARD_STATE_DIR}/.pending-port-finalization}"
VPSGUARD_SSHD_CONFIG="${VPSGUARD_SSHD_CONFIG:-${VPSGUARD_ETC_ROOT}/ssh/sshd_config.d/00-vpsguard.conf}"
SYSTEMD_SYSTEM_DIR="${SYSTEMD_SYSTEM_DIR:-${VPSGUARD_ETC_ROOT}/systemd/system}"
VPSGUARD_SSH_SOCKET_OVERRIDE="${VPSGUARD_SSH_SOCKET_OVERRIDE:-${SYSTEMD_SYSTEM_DIR}/ssh.socket.d/00-vpsguard.conf}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-${VPSGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local}"
SUDOERS_DIR="${SUDOERS_DIR:-${VPSGUARD_ETC_ROOT}/sudoers.d}"
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-${VPSGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf}"
BBR_MODULES_FILE="${BBR_MODULES_FILE:-${VPSGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf}"

GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BOLD="\033[1m"
NC="\033[0m"

section() {
  printf '\n%b==> %s%b\n' "${CYAN}${BOLD}" "$1" "$NC"
}

ok() {
  printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$1"
}

warn() {
  printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$1"
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

ufw_rule_exists_from_text() {
  local port="$1"
  awk -v target="${port}/tcp" '$1 == target {found=1} END {exit !found}'
}

ufw_tcp_rule_exists() {
  local port="$1"
  ufw status 2>/dev/null | ufw_rule_exists_from_text "$port"
}

sshd_value() {
  local output="$1"
  local key="$2"
  printf '%s\n' "$output" | awk -v wanted="$key" '$1 == wanted {print $2; exit}'
}

sshd_ports() {
  local output="$1"
  printf '%s\n' "$output" | awk '$1 == "port" && !seen[$2]++ {ports = ports (ports ? "," : "") $2} END {print ports}'
}

systemd_socket_listeners_from_text() {
  awk '
    NF {
      listener=$1
      if (!seen[listener]++) values = values (values ? "," : "") listener
    }
    END {print values ? values : "none"}
  '
}

systemd_socket_listeners_for_state_from_text() {
  local socket_state="$1"

  if [ "$socket_state" != "active" ]; then
    printf '%s\n' "$socket_state"
    return 0
  fi
  systemd_socket_listeners_from_text
}

ssh_listener_present() {
  local port="$1"
  local output="$2"
  printf '%s\n' "$output" | awk -v wanted="$port" '
    $1 == "LISTEN" {
      address=$4
      sub(/^.*:/, "", address)
      if (address == wanted && ($0 ~ /sshd/ || $0 ~ /systemd/)) found=1
    }
    END {exit !found}
  '
}


port_finalization_state() {
  local target_port="$1"
  local original_port="$2"
  local listeners="$3"
  local managed_snippet_state="$4"
  local pending_marker_state="$5"

  if [ "$pending_marker_state" = "present" ]; then
    printf 'pending\n'
    return 0
  fi

  if [ "$managed_snippet_state" = "present" ] \
    && [ -n "$target_port" ] \
    && ssh_listener_present "$target_port" "$listeners"; then
    if [ -z "$original_port" ] \
      || [ "$original_port" = "$target_port" ] \
      || ! ssh_listener_present "$original_port" "$listeners"; then
      printf 'complete\n'
      return 0
    fi

    printf 'incomplete\n'
    return 0
  fi

  if [ "$managed_snippet_state" = "missing" ] \
    && [ -n "$original_port" ] \
    && ssh_listener_present "$original_port" "$listeners"; then
    printf 'not-started\n'
    return 0
  fi

  printf 'incomplete\n'
}

service_state() {
  local unit="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemd-unavailable\n'
  elif systemctl is-active --quiet "$unit"; then
    printf 'active\n'
  elif systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk -v wanted="$unit" '$1 == wanted {found=1} END {exit !found}'; then
    printf 'inactive\n'
  else
    printf 'not-found\n'
  fi
}

sudo_policy_has_full_admin_from_text() {
  awk '
    /^[[:space:]]*\(ALL([[:space:]]*:[[:space:]]*ALL)?\)[[:space:]]+ALL[[:space:]]*$/ {found=1}
    END {exit !found}
  '
}

managed_file_is_owned() {
  local file="$1"
  [ -f "$file" ] && head -n 1 "$file" | grep -Eq '^# Managed by VPSGuard( |$)'
}

passwordless_sudo_effective_for_user() {
  local user="$1"

  sudo -u "$user" sudo -k >/dev/null 2>&1 || return 1
  sudo -u "$user" sudo -n true >/dev/null 2>&1 || return 1
  sudo -u "$user" sudo -n -i true >/dev/null 2>&1
}

configured_sudo_mode() {
  local value

  if ! value="$(read_env_value "$VPSGUARD_CONFIG_FILE" SUDO_MODE 2>/dev/null)"; then
    printf 'unverified\n'
    return 0
  fi
  case "$value" in
    password|passwordless) printf '%s\n' "$value" ;;
    *) printf 'invalid\n' ;;
  esac
}

main() {
  local managed_user ssh_port original_port install_status sudo_mode user_entry user_home user_shell
  local authorized_keys sudoers_file effective_sshd listeners available_cc current_cc current_qdisc key_owner
  local password_state sudo_policy sudo_group_member="no" passwordless_effective="no"
  local ssh_socket_state ssh_service_state sshd_service_state ufw_state="inactive"
  local client_address host_context effective_socket_listeners port_finalization

  if [ "$(id -u)" -ne 0 ]; then
    printf 'Please run status.sh as root so it can read protected VPSGuard state.\n' >&2
    exit 1
  fi

  if ! managed_user="$(read_env_value "$VPSGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then managed_user=""; fi
  if ! ssh_port="$(read_env_value "$VPSGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)"; then ssh_port=""; fi
  if ! original_port="$(read_env_value "$VPSGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)"; then original_port=""; fi
  if ! install_status="$(read_env_value "$VPSGUARD_CONFIG_FILE" INSTALL_STATUS 2>/dev/null)"; then install_status=""; fi
  sudo_mode="$(configured_sudo_mode)"

  section "VPSGuard"
  printf 'Version: %s\n' "$VPSGUARD_VERSION"
  printf 'Install status: %s\n' "${install_status:-not-configured}"
  printf 'Installed marker: %s\n' "$([ -f "$VPSGUARD_INSTALLED_MARKER" ] && printf present || printf missing)"
  printf 'Config: %s\n' "$VPSGUARD_CONFIG_FILE"
  printf 'State: %s\n' "$VPSGUARD_STATE_FILE"

  section "Managed administrator"
  printf 'Username: %s\n' "${managed_user:-not-configured}"
  if [ -n "$managed_user" ] && user_entry="$(getent passwd "$managed_user" 2>/dev/null)"; then
    user_home="$(printf '%s\n' "$user_entry" | awk -F: '{print $6}')"
    user_shell="$(printf '%s\n' "$user_entry" | awk -F: '{print $7}')"
    authorized_keys="${user_home}/.ssh/authorized_keys"
    sudoers_file="${SUDOERS_DIR}/vpsguard-${managed_user}"
    ok "User exists"
    printf 'Home: %s\nShell: %s\n' "$user_home" "$user_shell"
    if [ -s "$authorized_keys" ]; then
      printf 'authorized_keys: present and non-empty (contents hidden)\n'
      key_owner="$(stat -c '%U:%G' "$authorized_keys" 2>/dev/null || printf unknown)"
      printf 'authorized_keys owner: %s\n' "$key_owner"
      printf '.ssh mode: %s\n' "$(stat -c '%a' "${user_home}/.ssh" 2>/dev/null || printf unknown)"
      printf 'authorized_keys mode: %s\n' "$(stat -c '%a' "$authorized_keys" 2>/dev/null || printf unknown)"
    else
      warn "authorized_keys is missing or empty"
    fi
    if id -nG "$managed_user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then
      sudo_group_member="yes"
      ok "User is a member of the sudo group"
    else
      warn "User is not a member of the sudo group"
    fi
    if ! password_state="$(passwd -S "$managed_user" 2>/dev/null | awk '{print $2}')"; then
      password_state="unknown"
    fi
    printf 'Sudo mode: %s\n' "$sudo_mode"
    printf 'Password state: %s\n' "${password_state:-unknown}"
    printf 'Sudo group membership: %s\n' "$sudo_group_member"
    if [ "$password_state" = "P" ]; then
      ok "A sudo authentication password is set"
    else
      warn "Password state is ${password_state:-unknown}; standard sudo may be unusable"
    fi
    if managed_file_is_owned "$sudoers_file"; then
      printf 'Managed sudoers file: present (%s)\n' "$sudoers_file"
    elif [ -e "$sudoers_file" ]; then
      printf 'Managed sudoers file: unrecognized (%s)\n' "$sudoers_file"
    else
      printf 'Managed sudoers file: absent (%s)\n' "$sudoers_file"
    fi
    if [ -e "$sudoers_file" ] && visudo -cf "$sudoers_file" >/dev/null 2>&1; then
      printf 'visudo validation: valid\n'
    elif [ -e "$sudoers_file" ]; then
      printf 'visudo validation: invalid\n'
    elif visudo -c >/dev/null 2>&1; then
      printf 'visudo validation: valid (global)\n'
    else
      printf 'visudo validation: invalid (global)\n'
    fi
    if visudo -c >/dev/null 2>&1 && sudo_policy="$(LC_ALL=C sudo -l -U "$managed_user" 2>/dev/null)" && printf '%s\n' "$sudo_policy" | sudo_policy_has_full_admin_from_text; then
      ok "Standard full sudo policy is available through the distribution sudo group"
    else
      warn "Standard full sudo policy could not be verified"
    fi
    if passwordless_sudo_effective_for_user "$managed_user"; then
      passwordless_effective="yes"
    fi
    printf 'Passwordless sudo effective: %s\n' "$passwordless_effective"
    if [ "$sudo_mode" = "unverified" ]; then
      if [ "$passwordless_effective" = "yes" ]; then
        warn "No sudo mode has completed validation, but passwordless sudo is effective; configuration and actual behavior are inconsistent"
      else
        warn "No sudo mode has completed validation; password or passwordless must not be inferred from this state"
      fi
    fi
  else
    warn "Managed user does not exist"
  fi

  section "SSH"
  client_address="$(printf '%s\n' "${SSH_CONNECTION:-}" | awk 'NF >= 1 {print $1}')"
  host_context="$(hostname -f 2>/dev/null || hostname)"
  if [ -n "$managed_user" ] && [ -n "$client_address" ] && effective_sshd="$(sshd -T -C "user=${managed_user},host=${host_context},addr=${client_address}" 2>/dev/null)"; then
    :
  else
    if ! effective_sshd="$(sshd -T 2>/dev/null)"; then effective_sshd=""; fi
  fi
  if ! listeners="$(ss -ltnpH 2>/dev/null)"; then listeners=""; fi
  ssh_socket_state="$(service_state ssh.socket)"
  ssh_service_state="$(service_state ssh.service)"
  sshd_service_state="$(service_state sshd.service)"
  printf 'Expected port: %s\n' "${ssh_port:-not-configured}"
  printf 'Original port: %s\n' "${original_port:-unknown}"
  printf 'Effective port(s): %s\n' "$(sshd_ports "$effective_sshd")"
  if [ -n "$ssh_port" ] && ssh_listener_present "$ssh_port" "$listeners"; then
    printf 'Target listener: active\n'
  else
    printf 'Target listener: missing\n'
  fi
  printf 'ssh.socket: %s\nssh.service: %s\nsshd.service: %s\n' "$ssh_socket_state" "$ssh_service_state" "$sshd_service_state"
  printf 'PermitRootLogin: %s\n' "$(sshd_value "$effective_sshd" permitrootlogin)"
  printf 'PasswordAuthentication: %s\n' "$(sshd_value "$effective_sshd" passwordauthentication)"
  printf 'PubkeyAuthentication: %s\n' "$(sshd_value "$effective_sshd" pubkeyauthentication)"
  printf 'Managed SSH snippet: %s\n' "$([ -f "$VPSGUARD_SSHD_CONFIG" ] && printf present || printf missing)"
  printf 'Managed ssh.socket override: %s\n' "$([ -f "$VPSGUARD_SSH_SOCKET_OVERRIDE" ] && printf present || printf missing)"
  effective_socket_listeners=""
  if [ "$ssh_socket_state" = "active" ] && command -v systemctl >/dev/null 2>&1; then
    if ! effective_socket_listeners="$(systemctl show ssh.socket --property=Listen --value 2>/dev/null)"; then
      effective_socket_listeners=""
    fi
  fi
  printf 'Effective ssh.socket listeners: %s\n' "$(printf '%s\n' "$effective_socket_listeners" | systemd_socket_listeners_for_state_from_text "$ssh_socket_state")"
  port_finalization="$(port_finalization_state \
    "$ssh_port" \
    "$original_port" \
    "$listeners" \
    "$([ -f "$VPSGUARD_SSHD_CONFIG" ] && printf present || printf missing)" \
    "$([ -f "$VPSGUARD_PENDING_PORT_MARKER" ] && printf present || printf missing)")"
  printf 'Port finalization: %s\n' "$port_finalization"
  if sshd -t >/dev/null 2>&1; then
    printf 'sshd syntax: valid\n'
  else
    printf 'sshd syntax: invalid\n'
  fi

  section "UFW"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | awk 'NR == 1 && tolower($2) == "active" {found=1} END {exit !found}'; then
    ufw_state="active"
  fi
  printf 'State: %s\n' "$ufw_state"
  if [ -n "$ssh_port" ] && ufw_tcp_rule_exists "$ssh_port"; then
    printf 'Target SSH rule: present (%s/tcp)\n' "$ssh_port"
  else
    printf 'Target SSH rule: missing\n'
  fi
  if [ -n "$original_port" ] && [ "$original_port" != "$ssh_port" ]; then
    if ufw_tcp_rule_exists "$original_port"; then
      printf 'Old SSH rule: retained (%s/tcp)\n' "$original_port"
    else
      printf 'Old SSH rule: absent\n'
    fi
  fi

  section "fail2ban"
  printf 'Service: %s\n' "$(service_state fail2ban.service)"
  printf 'VPSGuard jail file: %s\n' "$([ -f "$FAIL2BAN_JAIL" ] && printf present || printf missing)"
  if fail2ban-client status sshd >/dev/null 2>&1; then
    printf 'sshd jail: active\n'
  else
    printf 'sshd jail: unavailable\n'
  fi

  section "BBR"
  if ! available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"; then available_cc=""; fi
  if ! current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"; then current_cc=""; fi
  if ! current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null)"; then current_qdisc=""; fi
  if printf ' %s ' "$available_cc" | grep -Fq ' bbr '; then
    printf 'Kernel support: supported\n'
  else
    printf 'Kernel support: unsupported-or-restricted\n'
  fi
  printf 'Available congestion controls: %s\n' "${available_cc:-unknown}"
  printf 'Current congestion control: %s\n' "${current_cc:-unknown}"
  printf 'Default qdisc: %s\n' "${current_qdisc:-unknown}"
  printf 'Persistent sysctl config: %s\n' "$([ -f "$BBR_SYSCTL_FILE" ] && printf present || printf missing)"
  printf 'modules-load config: %s\n' "$([ -f "$BBR_MODULES_FILE" ] && printf present || printf missing)"
}

if [ "$VPSGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
