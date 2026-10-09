#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_MANAGED_RULES="$HGUARD_STATE_DIR/managed-rules"
export HGUARD_BIN_DIR="$temporary_root/usr/local/sbin"
export HGUARD_LIB_DIR="$temporary_root/usr/local/lib/hguard"
export HGUARD_CLI_PATH="$HGUARD_BIN_DIR/hguard"
export APT_CONF_DIR="$temporary_root/etc/apt/apt.conf.d"
export HGUARD_APT_HOOK_FILE="$APT_CONF_DIR/99-hguard-verify"
# shellcheck source=uninstall.sh
. "$TEST_ROOT/uninstall.sh"

create_managed_conntrack_artifacts() {
  mkdir -p "$(dirname "$CONNTRACK_SYSCTL_FILE")" "$(dirname "$CONNTRACK_MODPROBE_FILE")"
  printf '# Managed by Hguard 0.3.6\nnet.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30\n' > "$CONNTRACK_SYSCTL_FILE"
  printf '# Managed by Hguard 0.3.6\noptions nf_conntrack hashsize=16384\n' > "$CONNTRACK_MODPROBE_FILE"
  mkdir -p "$(dirname "$CONNTRACK_MODULES_FILE")" "$(dirname "$CONNTRACK_HELPER_FILE")" "$(dirname "$CONNTRACK_SERVICE_FILE")"
  printf '# Managed by Hguard 0.3.6\nnf_conntrack\n' > "$CONNTRACK_MODULES_FILE"
  printf '# Managed by Hguard 0.3.6\n' > "$CONNTRACK_HELPER_FILE"
  printf '# Managed by Hguard 0.3.6\n[Service]\nType=oneshot\nRemainAfterExit=yes\n' > "$CONNTRACK_SERVICE_FILE"
}

assert_conntrack_artifacts_absent() {
  [ ! -e "$CONNTRACK_SYSCTL_FILE" ] || fail "managed conntrack sysctl file was not removed"
  [ ! -e "$CONNTRACK_MODPROBE_FILE" ] || fail "managed conntrack modprobe file was not removed"
  [ ! -e "$CONNTRACK_MODULES_FILE" ] || fail "managed conntrack modules-load file was not removed"
  [ ! -e "$CONNTRACK_HELPER_FILE" ] || fail "managed conntrack helper file was not removed"
  [ ! -e "$CONNTRACK_SERVICE_FILE" ] || fail "managed conntrack systemd unit was not removed"
}

managed="$temporary_root/managed.conf"
foreign="$temporary_root/foreign.conf"
printf '# Managed by Hguard 0.3.5\nvalue\n' > "$managed"
printf '# Managed by another tool\nvalue\n' > "$foreign"
remove_owned_file "$managed"
remove_owned_file "$foreign"
[ ! -e "$managed" ] || fail "managed file was not removed"
[ -e "$foreign" ] || fail "foreign file was removed"

create_managed_conntrack_artifacts
systemctl_log="$temporary_root/systemctl.log"
systemctl() {
  printf '%s\n' "$*" >> "$systemctl_log"
}
HGUARD_TEST_MODE=0
disable_owned_unit "$CONNTRACK_SERVICE_FILE" "$CONNTRACK_SERVICE_NAME"
HGUARD_TEST_MODE=1
assert_file_contains "$systemctl_log" "stop $CONNTRACK_SERVICE_NAME"
assert_file_contains "$systemctl_log" "disable $CONNTRACK_SERVICE_NAME"
assert_file_contains "$systemctl_log" 'daemon-reload'
remove_owned_file "$CONNTRACK_SYSCTL_FILE"
remove_owned_file "$CONNTRACK_MODPROBE_FILE"
remove_owned_file "$CONNTRACK_MODULES_FILE"
remove_owned_file "$CONNTRACK_HELPER_FILE"
remove_owned_file "$CONNTRACK_SERVICE_FILE"
assert_conntrack_artifacts_absent

printf '# custom kernel policy\nnet.netfilter.nf_conntrack_max = 131072\n' > "$CONNTRACK_SYSCTL_FILE"
remove_owned_file "$CONNTRACK_SYSCTL_FILE"
[ -e "$CONNTRACK_SYSCTL_FILE" ] || fail "foreign conntrack sysctl file was removed"

printf '# custom unit\n' > "$CONNTRACK_SERVICE_FILE"
rm -f "$systemctl_log"
HGUARD_TEST_MODE=0
disable_owned_unit "$CONNTRACK_SERVICE_FILE" "$CONNTRACK_SERVICE_NAME"
HGUARD_TEST_MODE=1
[ -e "$CONNTRACK_SERVICE_FILE" ] || fail "foreign conntrack systemd unit was removed"
[ ! -e "$systemctl_log" ] || fail "foreign conntrack systemd unit triggered systemctl"

rm -rf "${temporary_root:?}/etc" "$systemctl_log"
mkdir -p "$temporary_root/runtime"
printf '131072\n' > "$temporary_root/runtime/nf_conntrack_max"
printf '32768\n' > "$temporary_root/runtime/hashsize"
printf '120\n' > "$temporary_root/runtime/syn_sent"
create_managed_conntrack_artifacts
id() {
  if [ "${1:-}" = "-u" ]; then
    printf '0\n'
  else
    printf 'existingadmin sudo\n'
  fi
}
HGUARD_TEST_MODE=0
( main )
HGUARD_TEST_MODE=1
assert_conntrack_artifacts_absent
[ ! -d "$HGUARD_STATE_DIR" ] || fail "empty conntrack-only state directory was not removed"
assert_equal 131072 "$(cat "$temporary_root/runtime/nf_conntrack_max")" "conntrack-only cleanup preserves runtime max"
assert_equal 32768 "$(cat "$temporary_root/runtime/hashsize")" "conntrack-only cleanup preserves runtime hashsize"
assert_equal 120 "$(cat "$temporary_root/runtime/syn_sent")" "conntrack-only cleanup preserves runtime timeout"
assert_file_contains "$systemctl_log" "stop $CONNTRACK_SERVICE_NAME"
assert_file_contains "$systemctl_log" "disable $CONNTRACK_SERVICE_NAME"
assert_file_contains "$systemctl_log" 'daemon-reload'

rm -rf "${temporary_root:?}/etc" "$systemctl_log"
mkdir -p "$(dirname "$CONNTRACK_SYSCTL_FILE")" "$(dirname "$CONNTRACK_MODPROBE_FILE")" "$(dirname "$CONNTRACK_MODULES_FILE")" "$(dirname "$CONNTRACK_HELPER_FILE")" "$(dirname "$CONNTRACK_SERVICE_FILE")"
printf '# custom sysctl\n' > "$CONNTRACK_SYSCTL_FILE"
printf '# custom modprobe\n' > "$CONNTRACK_MODPROBE_FILE"
printf '# custom modules-load\n' > "$CONNTRACK_MODULES_FILE"
printf '# custom helper\n' > "$CONNTRACK_HELPER_FILE"
printf '# custom unit\n' > "$CONNTRACK_SERVICE_FILE"
cleanup_conntrack_artifacts
[ -e "$CONNTRACK_SYSCTL_FILE" ] || fail "foreign same-name conntrack sysctl was removed"
[ -e "$CONNTRACK_MODPROBE_FILE" ] || fail "foreign same-name conntrack modprobe was removed"
[ -e "$CONNTRACK_MODULES_FILE" ] || fail "foreign same-name conntrack modules-load was removed"
[ -e "$CONNTRACK_HELPER_FILE" ] || fail "foreign same-name conntrack helper was removed"
[ -e "$CONNTRACK_SERVICE_FILE" ] || fail "foreign same-name conntrack unit was removed"

rm -rf "${temporary_root:?}/etc" "$systemctl_log"
untracked_error="$temporary_root/untracked.err"
if ( main ) 2> "$untracked_error"; then
  fail "configless uninstall without conntrack artifacts succeeded"
fi
assert_file_contains "$untracked_error" 'refusing an untracked uninstall'

rm -rf "${temporary_root:?}/etc" "$systemctl_log"
mkdir -p "$HGUARD_STATE_DIR"
printf "NEW_USER='trackedadmin'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\nSUDO_MODE='password'\n" > "$HGUARD_CONFIG_FILE"
tracked_log="$temporary_root/tracked.log"
(
  remove_safe_ufw_rules() { printf 'ufw\n' >> "$tracked_log"; }
  remove_fail2ban_jail_safely() { printf 'fail2ban\n' >> "$tracked_log"; }
  remove_ssh_snippet_safely() { printf 'ssh\n' >> "$tracked_log"; }
  main <<< "UNINSTALL"
)
assert_file_contains "$tracked_log" 'ufw'
assert_file_contains "$tracked_log" 'fail2ban'
assert_file_contains "$tracked_log" 'ssh'
[ ! -e "$HGUARD_CONFIG_FILE" ] || fail "tracked uninstall did not remove config"

mkdir -p "$HGUARD_STATE_DIR"
printf '# UFW rules added by Hguard\n22/tcp\n2222/tcp\n' > "$HGUARD_MANAGED_RULES"
ufw_log="$temporary_root/ufw.log"
ufw() {
  if [ "$1" = status ]; then
    printf 'Status: active\n22/tcp ALLOW IN Anywhere\n2222/tcp ALLOW IN Anywhere\n'
  else
    printf '%s\n' "$*" >> "$ufw_log"
  fi
}
remove_safe_ufw_rules 22
assert_file_contains "$ufw_log" 'delete allow 2222/tcp'
if grep -Fq 'delete allow 22/tcp' "$ufw_log"; then
  fail "current SSH rule was deleted"
fi

if grep -Eq 'systemctl (stop|disable) fail2ban|ufw (--force )?(disable|reset)|userdel|deluser' "$TEST_ROOT/uninstall.sh"; then
  fail "unsafe global disable/reset or user deletion remains in uninstall.sh"
fi
assert_file_contains "$TEST_ROOT/uninstall.sh" 'systemctl disable'

mkdir -p "$SUDOERS_DIR"
sudoers_file="${SUDOERS_DIR}/hguard-existingadmin"
printf '# Managed by Hguard 0.3.5\nexistingadmin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudoers_file"
id() { printf 'existingadmin sudo\n'; }
# Called indirectly by remove_passwordless_sudoers_safely.
# shellcheck disable=SC2317,SC2329
passwd() { printf 'existingadmin P 2026-08-03 0 99999 7 -1\n'; }
visudo() { return 0; }
clear_cache_fail="false"
sudo() {
  if [ "${1:-}" = "-l" ]; then
    printf 'User existingadmin may run the following commands:\n    (ALL : ALL) ALL\n'
    return 0
  fi
  if [ "$*" = '-u existingadmin sudo -n true' ]; then
    return 1
  fi
  if [ "$*" = '-u existingadmin sudo -k' ]; then
    [ "$clear_cache_fail" != "true" ]
    return
  fi
  return 0
}
assert_success remove_passwordless_sudoers_safely existingadmin
[ ! -e "$sudoers_file" ] || fail "safe passwordless sudo policy was not removed"

printf '# Managed by Hguard 0.3.5\nexistingadmin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudoers_file"
# Called indirectly by remove_passwordless_sudoers_safely.
# shellcheck disable=SC2317,SC2329
passwd() { printf 'existingadmin L 2026-08-03 0 99999 7 -1\n'; }
assert_failure remove_passwordless_sudoers_safely existingadmin
[ -e "$sudoers_file" ] || fail "unsafe uninstall removed passwordless sudo without a valid password"

passwd() { printf 'existingadmin P 2026-08-03 0 99999 7 -1\n'; }
clear_cache_fail="true"
assert_failure remove_passwordless_sudoers_safely existingadmin
clear_cache_fail="false"
[ -e "$sudoers_file" ] || fail "uninstall removed sudoers when cache invalidation failed"

chmod 640 "$sudoers_file"
printf '# Managed by another tool\nexistingadmin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudoers_file"
assert_failure remove_passwordless_sudoers_safely existingadmin
[ -e "$sudoers_file" ] || fail "uninstall removed an unrecognized sudoers file"

mkdir -p "$(dirname "$SSHD_CONFIG")"
printf '%s\n' \
  '# BEGIN Hguard managed include' \
  'Include /etc/ssh/sshd_config.d/00-hguard.conf' \
  '# END Hguard managed include' \
  'PermitRootLogin prohibit-password' > "$SSHD_CONFIG"
assert_success remove_hguard_sshd_include
assert_file_contains "$SSHD_CONFIG" 'PermitRootLogin prohibit-password'
if grep -Fq 'Hguard managed include' "$SSHD_CONFIG"; then
  fail "managed sshd include markers remained after safe removal"
fi

pass "uninstall removes only owned policy/rules and preserves standard sudo, vendor SSH, services and users"

# Regression: before uninstall.sh shared install-core.sh's managed_file_is_owned
# via HGUARD_LIB_MODE sourcing, its own copy only checked line 1, so it never
# recognized a marker on line 2 (the conntrack helper's shebang-first format,
# e.g. CONNTRACK_HELPER_FILE) as Hguard-managed.
two_line_marker_file="$temporary_root/shebang-first.sh"
printf '#!/usr/bin/env bash\n# Managed by Hguard 0.4.0\n' > "$two_line_marker_file"
assert_success managed_file_is_owned "$two_line_marker_file"

pass "managed_file_is_owned recognizes the marker on line 2, not just line 1"

# Regression: uninstall.sh's own ufw_tcp_rule_exists used to check only
# `ufw status` and missed a rule that was added but not yet reflected there
# (`ufw show added`). Sharing install-core.sh's version via HGUARD_LIB_MODE
# picks up that check too.
ufw() {
  case "$1" in
    status) printf 'Status: active\n' ;;
    show) [ "$2" = "added" ] && printf 'ufw allow 2345/tcp\n' ;;
  esac
}
assert_success ufw_tcp_rule_exists 2345

pass "ufw_tcp_rule_exists also checks ufw show added, not just ufw status"

# any_generation_marker_owns is for migration/status/uninstall callers that
# need to find a leftover VPSGuard-era (pre-rename) file too; it must not
# become the default check used when writing or validating a current file.
current_marker_file="$temporary_root/current.conf"
legacy_marker_file="$temporary_root/legacy.conf"
unrecognized_file="$temporary_root/unrecognized.conf"
printf '# Managed by Hguard 0.4.0\n' > "$current_marker_file"
printf '# Managed by VPSGuard 0.3.7\n' > "$legacy_marker_file"
printf '# Managed by SomethingElse\n' > "$unrecognized_file"

assert_success any_generation_marker_owns "$current_marker_file"
assert_success any_generation_marker_owns "$legacy_marker_file"
assert_failure any_generation_marker_owns "$unrecognized_file"
assert_success managed_file_is_owned "$current_marker_file"
assert_failure managed_file_is_owned "$legacy_marker_file"

pass "any_generation_marker_owns recognizes both the current and legacy VPSGuard marker"

# remove_hguard_cli_and_hook removes the dispatcher, its whole lib
# directory, and the apt hook - but only once the dispatcher itself is
# positively recognized as Hguard-managed; an unrecognized file at that
# path must be preserved, same as everywhere else.
mkdir -p "$HGUARD_LIB_DIR" "$APT_CONF_DIR" "$(dirname "$HGUARD_CLI_PATH")"
printf '#!/usr/bin/env bash\n# Managed by Hguard 0.4.0\n' > "$HGUARD_CLI_PATH"
printf '#!/usr/bin/env bash\n' > "${HGUARD_LIB_DIR}/status.sh"
printf '# Managed by Hguard 0.4.0\nDPkg::Post-Invoke {};\n' > "$HGUARD_APT_HOOK_FILE"

remove_hguard_cli_and_hook
[ ! -e "$HGUARD_CLI_PATH" ] || fail "the hguard dispatcher was not removed"
[ ! -d "$HGUARD_LIB_DIR" ] || fail "the hguard lib directory was not removed"
[ ! -e "$HGUARD_APT_HOOK_FILE" ] || fail "the apt hook file was not removed"

mkdir -p "$(dirname "$HGUARD_CLI_PATH")"
printf '#!/usr/bin/env bash\necho not ours\n' > "$HGUARD_CLI_PATH"
remove_hguard_cli_and_hook
[ -e "$HGUARD_CLI_PATH" ] || fail "an unrecognized file at the hguard CLI path must be preserved, not removed"

pass "remove_hguard_cli_and_hook removes the managed CLI/hook, and preserves an unrecognized dispatcher file"

# Regression: the apt hook's own state files (last verification result/
# timestamp and the package-version snapshot it diffs against) were
# left behind after uninstall, which is why /etc/hguard was reported
# "not empty" and preserved instead of removed - run the hook once for
# real to produce them, then uninstall and confirm the whole state
# directory is gone.
mkdir -p "$HGUARD_LIB_DIR" "$APT_CONF_DIR" "$(dirname "$HGUARD_CLI_PATH")" "$SUDOERS_DIR"
printf '#!/usr/bin/env bash\n# Managed by Hguard 0.4.0\n' > "$HGUARD_CLI_PATH"
printf '# Managed by Hguard 0.4.0\nDPkg::Post-Invoke {};\n' > "$HGUARD_APT_HOOK_FILE"
printf "NEW_USER='trackedadmin'\nSUDO_MODE='password'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"
# The subshell is required here, not just convenient: apt-hook.sh defines
# its own main() and re-sources install-core.sh, which would overwrite
# this file's own main() (uninstall.sh's) and HGUARD_* path variables for
# everything after it if sourced at the top level instead. That re-
# sourcing is also why re-sourcing install-core.sh's HGUARD_*=${HGUARD_*:-
# default} assignments inside this subshell makes shellcheck flag every
# later read of those same variables, for the rest of the file, as
# possibly stale (SC2031) - disabled file-wide below with the reason.
(
  # shellcheck source=apt-hook.sh
  . "$TEST_ROOT/apt-hook.sh"
  id() { [ "${1:-}" = "-u" ] && printf '0\n' || return 0; }
  apt-cache() { [ "$1" = "policy" ] || return 1; printf '%s:\n  Installed: 1.0\n  Candidate: 1.0\n' "$2"; }
  validate_existing_user_account() { :; }
  verify_authorized_keys() { return 0; }
  verify_sudo_configuration() { return 0; }
  verify_effective_sshd_config() { return 0; }
  verify_ssh_runtime_healthy() { return 0; }
  verify_ssh_listener() { return 0; }
  ufw_is_active() { return 0; }
  ufw_tcp_rule_exists() { return 0; }
  verify_config_permissions() { return 0; }
  systemctl() { return 0; }
  fail2ban-client() { return 0; }
  sysctl() { [ "$2" = "net.ipv4.tcp_congestion_control" ] && printf 'bbr\n' || printf 'fq\n'; }
  main
)
# shellcheck disable=SC2031
{
  [ -f "$HGUARD_APT_HOOK_STATE_FILE" ] || fail "setup failed: the apt hook did not produce a state file"
  [ -f "$HGUARD_APT_HOOK_VERSIONS_FILE" ] || fail "setup failed: the apt hook did not produce a versions snapshot"

  remove_hguard_cli_and_hook
  [ ! -e "$HGUARD_APT_HOOK_STATE_FILE" ] || fail "the apt hook's verification state file was not removed"
  [ ! -e "$HGUARD_APT_HOOK_VERSIONS_FILE" ] || fail "the apt hook's version snapshot was not removed"

  rm -f "$HGUARD_PENDING_PORT_MARKER" "$HGUARD_MANAGED_RULES" "$HGUARD_CONFIG_FILE" "$HGUARD_STATE_FILE" \
    "${HGUARD_STATE_DIR}/.ssh_done" "${HGUARD_STATE_DIR}/.sudo_done" "${HGUARD_STATE_DIR}/.ufw_done"
  rmdir "$HGUARD_STATE_DIR" 2>/dev/null || fail "the state directory was not empty after removing the apt hook's state files (contents: $(ls -la "$HGUARD_STATE_DIR" 2>&1))"
}

pass "remove_hguard_cli_and_hook also removes the apt hook's own state/version files, leaving the state directory empty"

# Item 2: the pre-migration VPSGuard backup directory. Only removed when
# it is positively identified by MIGRATED-TO-HGUARD, and only on a fully
# successful (no leftovers) uninstall.
# shellcheck disable=SC2031
{
  id() { [ "${1:-}" = "-u" ] && printf '0\n' || printf 'trackedadmin sudo\n'; }
  rm -rf "${temporary_root:?}/vpsguard-backup-test"
  mkdir -p "${temporary_root}/vpsguard-backup-test"
  export VPSGUARD_LEGACY_STATE_DIR="${temporary_root}/vpsguard-backup-test"
  export VPSGUARD_MIGRATED_MARKER_FILE="${VPSGUARD_LEGACY_STATE_DIR}/MIGRATED-TO-HGUARD"
  mkdir -p "$HGUARD_STATE_DIR"
  printf "NEW_USER='trackedadmin'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\nSUDO_MODE='password'\n" > "$HGUARD_CONFIG_FILE"

  # Case A: a genuine VPSGuard backup (marker present) + a fully successful
  # uninstall -> the whole backup directory is removed.
  printf '.installed\n' > "${VPSGUARD_LEGACY_STATE_DIR}/.installed"
  printf 'Migrated to Hguard 0.4.0 at 2026-01-01T00:00:00Z.\n' > "$VPSGUARD_MIGRATED_MARKER_FILE"
  remove_safe_ufw_rules() { :; }
  remove_fail2ban_jail_safely() { :; }
  remove_ssh_snippet_safely() { :; }
  main <<< "UNINSTALL"
  [ ! -d "$VPSGUARD_LEGACY_STATE_DIR" ] || fail "the VPSGuard backup was not removed after a fully successful uninstall"

  # Case B: a genuine VPSGuard backup, but the uninstall only partially
  # succeeds (SSH removal fails) -> the backup must be left alone.
  mkdir -p "$HGUARD_STATE_DIR" "$VPSGUARD_LEGACY_STATE_DIR"
  printf "NEW_USER='trackedadmin'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\nSUDO_MODE='password'\n" > "$HGUARD_CONFIG_FILE"
  printf 'Migrated to Hguard 0.4.0 at 2026-01-01T00:00:00Z.\n' > "$VPSGUARD_MIGRATED_MARKER_FILE"
  remove_ssh_snippet_safely() { return 1; }
  main <<< "UNINSTALL"
  [ -d "$VPSGUARD_LEGACY_STATE_DIR" ] || fail "the VPSGuard backup was removed despite a partial (leftovers=true) uninstall"
  rm -f "$HGUARD_CONFIG_FILE"

  # Case C: a directory at the legacy vpsguard path with no MIGRATED
  # marker - not positively identified as Hguard's backup, so it must be
  # left alone even on a fully successful uninstall.
  rm -f "$VPSGUARD_MIGRATED_MARKER_FILE"
  mkdir -p "$HGUARD_STATE_DIR"
  printf "NEW_USER='trackedadmin'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\nSUDO_MODE='password'\n" > "$HGUARD_CONFIG_FILE"
  remove_ssh_snippet_safely() { :; }
  main <<< "UNINSTALL"
  [ -d "$VPSGUARD_LEGACY_STATE_DIR" ] || fail "an unmarked directory at the legacy vpsguard path was removed without positive identification"
}

pass "uninstall removes the pre-migration VPSGuard backup only when positively marked and the uninstall fully succeeds"
