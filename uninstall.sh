#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HGUARD_LIB_MODE=1
# shellcheck source=install-core.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/install-core.sh"

# install-core.sh's info()/warn()/error() also append to HGUARD_LOG_FILE.
# Keep uninstall's own non-logging behavior, unchanged from before.
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

# Deliberately not install-core.sh's apply_ssh_runtime(): that version
# depends on detect_ssh_runtime_mode()'s install-flow-only state
# ($SSH_RUNTIME_MODE/$SSH_SERVICE_UNIT) and has materially different
# fallback logic. Uninstall's own self-contained version predates that
# function and is kept as-is rather than risk changing behavior on the
# SSH-safety-critical removal path.
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
    info "Removed Hguard-managed file: ${file}"
  elif [ -e "$file" ]; then
    warn "Preserved unrecognized file: ${file}"
  fi
}

# The dispatcher (HGUARD_CLI_PATH) is written via atomic_write with the
# ownership marker, so managed_file_is_owned recognizes it directly. The
# lib scripts under HGUARD_LIB_DIR are plain copies (no marker line) -
# treat that whole directory as Hguard-owned only once the marked
# dispatcher confirms this is really an Hguard-managed installation, same
# "don't touch what we can't positively identify" rule as everything else.
remove_hguard_cli_and_hook() {
  if managed_file_is_owned "$HGUARD_APT_HOOK_FILE"; then
    rm -f "$HGUARD_APT_HOOK_FILE"
    info "Removed Hguard-managed file: ${HGUARD_APT_HOOK_FILE}"
    # The hook's own state - last verification result/timestamp and the
    # package-version snapshot it diffs against - has no purpose once
    # the hook itself is gone, and leaving it behind is why the state
    # directory wasn't empty and got preserved instead of removed below.
    rm -f "$HGUARD_APT_HOOK_STATE_FILE" "$HGUARD_APT_HOOK_VERSIONS_FILE"
  elif [ -e "$HGUARD_APT_HOOK_FILE" ]; then
    warn "Preserved unrecognized file: ${HGUARD_APT_HOOK_FILE}"
  fi
  if managed_file_is_owned "$HGUARD_CLI_PATH"; then
    rm -f "$HGUARD_CLI_PATH"
    info "Removed Hguard-managed file: ${HGUARD_CLI_PATH}"
    if [ -d "$HGUARD_LIB_DIR" ]; then
      rm -rf "$HGUARD_LIB_DIR"
      info "Removed the hguard CLI library directory: ${HGUARD_LIB_DIR}"
    fi
  elif [ -e "$HGUARD_CLI_PATH" ]; then
    warn "Preserved unrecognized file: ${HGUARD_CLI_PATH}"
  fi
}

disable_owned_unit() {
  local unit_file="$1"
  local unit_name="$2"

  if managed_file_is_owned "$unit_file"; then
    if [ "$HGUARD_TEST_MODE" != "1" ] && command -v systemctl >/dev/null 2>&1; then
      systemctl stop "$unit_name" >/dev/null 2>&1 || warn "Could not stop ${unit_name}; removing the managed unit file anyway."
      systemctl disable "$unit_name" >/dev/null 2>&1 || warn "Could not disable ${unit_name}; removing the managed unit file anyway."
      systemctl daemon-reload || warn "systemctl daemon-reload failed after disabling ${unit_name}."
    fi
  elif [ -e "$unit_file" ]; then
    warn "Preserved unrecognized unit file: ${unit_file}"
  fi
}

reload_systemd_after_conntrack_cleanup() {
  if [ "$HGUARD_TEST_MODE" != "1" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || warn "systemctl daemon-reload failed after conntrack cleanup."
  fi
}

conntrack_managed_artifact_exists() {
  managed_file_is_owned "$CONNTRACK_SYSCTL_FILE" \
    || managed_file_is_owned "$CONNTRACK_MODPROBE_FILE" \
    || managed_file_is_owned "$CONNTRACK_MODULES_FILE" \
    || managed_file_is_owned "$CONNTRACK_SERVICE_FILE" \
    || managed_file_is_owned "$CONNTRACK_HELPER_FILE"
}

cleanup_empty_state_dir() {
  [ -d "$HGUARD_STATE_DIR" ] || return 0
  rmdir "$HGUARD_STATE_DIR" 2>/dev/null || true
}

cleanup_conntrack_artifacts() {
  disable_owned_unit "$CONNTRACK_SERVICE_FILE" "$CONNTRACK_SERVICE_NAME"
  remove_owned_file "$CONNTRACK_SYSCTL_FILE"
  remove_owned_file "$CONNTRACK_MODPROBE_FILE"
  remove_owned_file "$CONNTRACK_MODULES_FILE"
  remove_owned_file "$CONNTRACK_SERVICE_FILE"
  remove_owned_file "$CONNTRACK_HELPER_FILE"
  reload_systemd_after_conntrack_cleanup
  warn "Runtime nf_conntrack_max, hashsize and timeout values were not forced downward; reboot may be required for system or other persistent configuration to become effective."
}

cleanup_conntrack_only_without_config() {
  printf '\n%bHguard %s conntrack cleanup%b\n' "$BOLD" "$HGUARD_VERSION" "$NC"
  cleanup_conntrack_artifacts
  cleanup_empty_state_dir
  info "Conntrack-only cleanup completed."
}

remove_safe_ufw_rules() {
  local target_port="$1"
  local rule port

  [ -f "$HGUARD_MANAGED_RULES" ] || return 0
  if [ -f "$HGUARD_PENDING_PORT_MARKER" ]; then
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
      info "Removed recorded Hguard UFW rule ${rule}."
    fi
  done < "$HGUARD_MANAGED_RULES"
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

remove_hguard_sshd_include() {
  local temporary_file begin_count end_count begin_line end_line mode

  if ! begin_count="$(grep -Fxc "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG")"; then begin_count=0; fi
  if ! end_count="$(grep -Fxc "$SSHD_INCLUDE_END" "$SSHD_CONFIG")"; then end_count=0; fi
  if [ "$begin_count" -eq 0 ] && [ "$end_count" -eq 0 ]; then
    return 0
  fi
  if [ "$begin_count" -ne 1 ] || [ "$end_count" -ne 1 ]; then
    warn "Malformed Hguard include markers were preserved in ${SSHD_CONFIG}."
    return 1
  fi
  begin_line="$(grep -Fn "$SSHD_INCLUDE_BEGIN" "$SSHD_CONFIG" | cut -d: -f1)"
  end_line="$(grep -Fn "$SSHD_INCLUDE_END" "$SSHD_CONFIG" | cut -d: -f1)"
  if [ "$begin_line" -ge "$end_line" ]; then
    warn "Out-of-order Hguard include markers were preserved in ${SSHD_CONFIG}."
    return 1
  fi
  temporary_file="$(mktemp "${SSHD_CONFIG}.uninstall.XXXXXX")"
  awk -v begin="$SSHD_INCLUDE_BEGIN" -v end="$SSHD_INCLUDE_END" '
    $0 == begin {inside=1; next}
    $0 == end {inside=0; next}
    !inside {print}
  ' "$SSHD_CONFIG" > "$temporary_file"
  mode="$(stat -c '%a' "$SSHD_CONFIG" 2>/dev/null || printf 644)"
  chmod "$mode" "$temporary_file"
  if [ "$HGUARD_TEST_MODE" != "1" ]; then
    chown root:root "$temporary_file"
  fi
  mv -f "$temporary_file" "$SSHD_CONFIG"
}

remove_ssh_snippet_safely() {
  local target_port="$1"
  local original_port="$2"
  local main_backup snippet_backup="" socket_backup=""

  if [ -e "$HGUARD_SSHD_CONFIG" ] && ! managed_file_is_owned "$HGUARD_SSHD_CONFIG"; then
    warn "SSH snippet is not recognizable as Hguard-managed; preserving it."
    return 1
  fi
  if [ -e "$HGUARD_SSH_SOCKET_OVERRIDE" ] && ! managed_file_is_owned "$HGUARD_SSH_SOCKET_OVERRIDE"; then
    warn "ssh.socket override is not recognizable as Hguard-managed; preserving it."
    return 1
  fi
  if [ "$target_port" != "$original_port" ] || [ -f "$HGUARD_PENDING_PORT_MARKER" ]; then
    warn "Hguard SSH policy was preserved because removing a changed/pending port remotely could cause lockout."
    return 1
  fi

  main_backup="$(mktemp "${SSHD_CONFIG}.hguard-backup.XXXXXX")"
  cp -p "$SSHD_CONFIG" "$main_backup"
  if [ -e "$HGUARD_SSHD_CONFIG" ]; then
    snippet_backup="$(mktemp "${HGUARD_SSHD_CONFIG}.uninstall.XXXXXX")"
    cp -p "$HGUARD_SSHD_CONFIG" "$snippet_backup"
  fi
  if [ -e "$HGUARD_SSH_SOCKET_OVERRIDE" ]; then
    socket_backup="$(mktemp "${HGUARD_SSH_SOCKET_OVERRIDE}.uninstall.XXXXXX")"
    cp -p "$HGUARD_SSH_SOCKET_OVERRIDE" "$socket_backup"
  fi

  remove_hguard_sshd_include || return 1
  rm -f "$HGUARD_SSHD_CONFIG"
  rm -f "$HGUARD_SSH_SOCKET_OVERRIDE"
  if sshd -t && apply_ssh_runtime; then
    rm -f "$main_backup"
    [ -z "$snippet_backup" ] || rm -f "$snippet_backup"
    [ -z "$socket_backup" ] || rm -f "$socket_backup"
    info "Removed Hguard SSH include, snippet and socket override after syntax and runtime validation."
    return 0
  fi

  mv -f "$main_backup" "$SSHD_CONFIG"
  [ -z "$snippet_backup" ] || mv -f "$snippet_backup" "$HGUARD_SSHD_CONFIG"
  [ -z "$socket_backup" ] || mv -f "$socket_backup" "$HGUARD_SSH_SOCKET_OVERRIDE"
  if ! apply_ssh_runtime; then
    warn "The SSH policy was restored, but runtime re-application also failed. Keep the current session open and inspect SSH manually."
  fi
  warn "SSH restoration could not be validated; the Hguard policy was restored."
  return 1
}

remove_passwordless_sudoers_safely() {
  local managed_user="$1"
  local sudoers_file backup password_state policy_output

  sudoers_file="${SUDOERS_DIR}/hguard-${managed_user}"
  [ -e "$sudoers_file" ] || return 0
  if ! managed_file_is_owned "$sudoers_file"; then
    warn "Preserved unrecognized sudoers file: ${sudoers_file}"
    return 1
  fi
  if ! id -nG "$managed_user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sudo; then
    warn "Preserved passwordless sudoers file because ${managed_user} is not in the sudo group."
    return 1
  fi
  if ! password_state="$(passwd -S "$managed_user" 2>/dev/null | awk '{print $2}')"; then
    password_state="unknown"
  fi
  if [ "$password_state" != "P" ]; then
    warn "Preserved passwordless sudoers file because ${managed_user} has no usable sudo password."
    return 1
  fi

  if ! backup="$(mktemp "${sudoers_file}.uninstall.XXXXXX")" \
    || ! cp -p "$sudoers_file" "$backup"; then
    [ -z "${backup:-}" ] || rm -f "$backup"
    warn "Could not create a sudoers rollback copy; preserved ${sudoers_file}."
    return 1
  fi
  if ! rm -f "$sudoers_file"; then
    mv -f "$backup" "$sudoers_file"
    warn "Could not stage removal of ${sudoers_file}; the rollback copy was restored."
    return 1
  fi
  if visudo -c >/dev/null 2>&1 \
    && policy_output="$(LC_ALL=C sudo -l -U "$managed_user" 2>/dev/null)" \
    && printf '%s\n' "$policy_output" | sudo_policy_has_full_admin_from_text; then
    if ! sudo -u "$managed_user" sudo -k >/dev/null 2>&1; then
      mv -f "$backup" "$sudoers_file"
      warn "Could not clear the sudo credential cache; restored ${sudoers_file}."
      return 1
    fi
    if ! sudo -u "$managed_user" sudo -n true >/dev/null 2>&1; then
      rm -f "$backup"
      info "Removed the Hguard passwordless sudo policy; standard password-authenticated sudo remains available."
      return 0
    fi
  fi

  mv -f "$backup" "$sudoers_file"
  warn "Could not prove safe standard sudo access; restored ${sudoers_file}."
  return 1
}

main() {
  local managed_user target_port original_port sudo_mode confirmation ssh_removed="true"
  local leftovers="false"

  [ "$(id -u)" -eq 0 ] || error "Please run uninstall.sh as root."
  if ! managed_user="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)"; then managed_user=""; fi
  if ! target_port="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)"; then target_port=""; fi
  if ! original_port="$(read_env_value "$HGUARD_CONFIG_FILE" ORIGINAL_SSH_PORT 2>/dev/null)"; then original_port=""; fi
  if ! sudo_mode="$(read_env_value "$HGUARD_CONFIG_FILE" SUDO_MODE 2>/dev/null)"; then sudo_mode="password"; fi
  if [ -z "$managed_user" ]; then
    if conntrack_managed_artifact_exists; then
      cleanup_conntrack_only_without_config
      return 0
    fi
    error "Hguard config is missing or invalid; refusing an untracked uninstall."
  fi
  case "$sudo_mode" in
    password|passwordless) ;;
    *) error "Hguard config contains an invalid SUDO_MODE; refusing an untracked sudoers change." ;;
  esac

  printf '\n%bHguard %s safe uninstall%b\n' "$BOLD" "$HGUARD_VERSION" "$NC"
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
  cleanup_conntrack_artifacts
  remove_hguard_cli_and_hook

  if [ "$sudo_mode" = "passwordless" ]; then
    if ! remove_passwordless_sudoers_safely "$managed_user"; then
      leftovers="true"
    fi
  fi
  info "Administrator account ${managed_user} and all user files were preserved."

  rm -f "$HGUARD_INSTALLED_MARKER"
  if [ "$ssh_removed" = "true" ] && [ "$leftovers" = "false" ]; then
    rm -f "$HGUARD_PENDING_PORT_MARKER" "$HGUARD_MANAGED_RULES" "$HGUARD_CONFIG_FILE" "$HGUARD_STATE_FILE" \
      "${HGUARD_STATE_DIR}/.ssh_done" "${HGUARD_STATE_DIR}/.sudo_done" "${HGUARD_STATE_DIR}/.ufw_done"
    if ! rmdir "$HGUARD_STATE_DIR" 2>/dev/null; then
      warn "State directory was not empty and was preserved: ${HGUARD_STATE_DIR}"
    fi
    # Only once everything above is confirmed fully, safely removed: the
    # pre-migration VPSGuard backup has no remaining purpose, and the
    # MIGRATED-TO-HGUARD marker is what positively identifies this
    # directory as that backup (rather than something unrelated that
    # happens to live at the same legacy path) - same "don't touch what
    # we can't positively identify" rule as everything else here.
    if [ -f "$VPSGUARD_MIGRATED_MARKER_FILE" ]; then
      rm -rf "$VPSGUARD_LEGACY_STATE_DIR"
      info "Removed the pre-migration VPSGuard backup: ${VPSGUARD_LEGACY_STATE_DIR}"
    fi
    info "Safe uninstall completed."
  else
    warn "Uninstall completed partially. State was retained because SSH or sudo safety prevented full removal."
  fi
}

if [ "$HGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
