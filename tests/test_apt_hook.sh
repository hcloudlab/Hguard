#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_CONFIG_FILE="$HGUARD_STATE_DIR/config.env"
export APT_CONF_DIR="$temporary_root/etc/apt/apt.conf.d"
export HGUARD_APT_HOOK_FILE="$APT_CONF_DIR/99-hguard-verify"
export HGUARD_APT_HOOK_SCRIPT="$temporary_root/usr/local/lib/hguard/apt-hook.sh"
export HGUARD_APT_HOOK_STATE_FILE="$HGUARD_STATE_DIR/apt-hook-verify.env"
export HGUARD_APT_HOOK_VERSIONS_FILE="$HGUARD_STATE_DIR/apt-hook-versions.env"
mkdir -p "$HGUARD_STATE_DIR" "$APT_CONF_DIR"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

### install_apt_hook writes the managed Post-Invoke file, calling the
### script at HGUARD_APT_HOOK_SCRIPT and always tolerating its failure.
assert_success install_apt_hook
assert_file_contains "$HGUARD_APT_HOOK_FILE" "# Managed by Hguard"
assert_file_contains "$HGUARD_APT_HOOK_FILE" "DPkg::Post-Invoke"
assert_file_contains "$HGUARD_APT_HOOK_FILE" "${HGUARD_APT_HOOK_SCRIPT} || true"

pass "install_apt_hook writes a managed DPkg::Post-Invoke hook pointing at apt-hook.sh"

### apt-hook.sh itself, sourced for its functions (HGUARD_TEST_MODE skips
### both its own main() and the `trap exit 0` that would otherwise mask
### test failures - see the comment in apt-hook.sh).
# shellcheck source=apt-hook.sh
. "$TEST_ROOT/apt-hook.sh"

id() { [ "$1" = "-u" ] && printf '0\n' || return 0; }
printf "NEW_USER='admin'\nSUDO_MODE='password'\nSSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"
apt-cache() {
  [ "$1" = "policy" ] || return 1
  printf '%s:\n  Installed: 1.0\n  Candidate: 1.0\n' "$2"
}
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

### First run: no versions file yet, so the snapshot always "changes" ->
### verify runs and the result is recorded.
rm -f "$HGUARD_APT_HOOK_VERSIONS_FILE" "$HGUARD_APT_HOOK_STATE_FILE"
main
assert_file_contains "$HGUARD_APT_HOOK_STATE_FILE" "RESULT='PASS'"
[ -s "$HGUARD_APT_HOOK_VERSIONS_FILE" ] || fail "the version snapshot was not recorded"

### Second run: nothing changed -> verify must not run again. Delete the
### result file and confirm it stays deleted (a no-op run never recreates
### it), proving the version-unchanged short-circuit actually took effect.
rm -f "$HGUARD_APT_HOOK_STATE_FILE"
main
[ ! -e "$HGUARD_APT_HOOK_STATE_FILE" ] || fail "apt-hook.sh re-ran verify when no managed package version changed"

### Third run: a version changed -> verify runs again, and failing checks
### are recorded as FAIL rather than silently passing.
apt-cache() {
  [ "$1" = "policy" ] || return 1
  printf '%s:\n  Installed: 2.0\n  Candidate: 2.0\n' "$2"
}
ufw_is_active() { return 1; }
main
assert_file_contains "$HGUARD_APT_HOOK_STATE_FILE" "RESULT='FAIL'"

pass "apt-hook.sh only reverifies when a managed package's version actually changed, and records PASS/FAIL"

### Never fails the invoking apt run: even with HGUARD_CONFIG_FILE missing
### entirely (nothing configured yet), the script must exit 0.
rm -f "$HGUARD_CONFIG_FILE"
(exit_code=0; main || exit_code=$?; [ "$exit_code" -eq 0 ]) || fail "apt-hook.sh's main must return 0 even when nothing is configured"

pass "apt-hook.sh never fails even when Hguard is not configured yet"
