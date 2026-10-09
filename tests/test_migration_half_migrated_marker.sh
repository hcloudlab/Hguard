#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# Covers the exact "half-migrated" state this is a regression test for:
# a machine where migrate_from_vpsguard already ran (there is no /etc/
# vpsguard directory left to migrate from - migrate_from_vpsguard_needed
# is false, just like after a real, completed migration), but one or more
# Hguard-named managed files still carry the old "Managed by VPSGuard"
# marker, because they were copied verbatim by a migration that predates
# the marker-relabeling fix. A fixed installer rerunning against this
# state must recognize and correct it by itself - not refuse with
# "unrecognized existing file", and not require deleting anything by
# hand. This is independent of (and a smaller, synthetic complement to)
# test_migration_e2e_aws.sh/vultr.sh's full real-fixture coverage, chosen
# specifically to exercise passwordless-mode sudoers - the one marker-
# gated write path neither real fixture's password-mode sudo configuration
# reaches, since passwordless_sudo never had an AWS/Vultr-captured
# equivalent to import.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_RUN_ROOT="$temporary_root/run"
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
mkdir -p "$HGUARD_ETC_ROOT" "$HGUARD_ETC_ROOT/ssh/sshd_config.d" "$HGUARD_ETC_ROOT/fail2ban/jail.d" \
  "$HGUARD_ETC_ROOT/sudoers.d" "$HGUARD_ETC_ROOT/sysctl.d"
mkdir -p "$APT_CONF_DIR"
{
  printf 'ID=ubuntu\n'
  printf 'VERSION_ID="24.04"\n'
  printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\n'
} > "${HGUARD_ETC_ROOT}/os-release"
{
  printf '# This is the sshd server system-wide configuration file.\n'
  printf 'Include %s/ssh/sshd_config.d/*.conf\n' "$HGUARD_ETC_ROOT"
} > "${HGUARD_ETC_ROOT}/ssh/sshd_config"
unset NEW_USER SSH_PORT ALLOW_PORTS 2>/dev/null || true
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

mkdir -p "$HGUARD_STATE_DIR"
chmod 700 "$HGUARD_STATE_DIR"
{
  printf "# Managed by VPSGuard 0.3.7; values are validated before use.\n"
  printf "NEW_USER='hadmin'\n"
  printf "SUDO_MODE='passwordless'\n"
  printf "SSH_PORT='22'\n"
  printf "ORIGINAL_SSH_PORT='22'\n"
  printf "INSTALL_STATUS='success'\n"
} > "$HGUARD_CONFIG_FILE"
chmod 600 "$HGUARD_CONFIG_FILE"

# An Hguard-named fail2ban jail, left over from a migration that predates
# the marker-relabeling fix: still carries the VPSGuard marker.
{
  printf '# Managed by VPSGuard 0.3.7\n'
  printf '[sshd]\nenabled = true\nport = 22\nfilter = sshd\nbackend = systemd\n'
  printf 'maxretry = 5\nfindtime = 10m\nbantime = 1h\nignoreip = 127.0.0.1/8 ::1\n'
} > "$FAIL2BAN_JAIL"

# An Hguard-named passwordless sudoers file, same leftover scenario.
{
  printf '# Managed by VPSGuard 0.3.7; passwordless sudo mode.\n'
  printf 'hadmin ALL=(ALL:ALL) NOPASSWD: ALL\n'
} > "$(sudoers_file_for_user)"
chmod 440 "$(sudoers_file_for_user)"

### Requirement 2's core fix, directly: these must no longer be refused.
assert_success assert_managed_or_absent "$FAIL2BAN_JAIL"
assert_success any_generation_marker_owns "$(sudoers_file_for_user)"

export BBR_MODULE_PERSISTENCE_REQUIRED=true
require_root() { :; }
ensure_managed_user() { :; }
configure_authorized_keys() { :; }
check_root_ssh_key() { :; }
verify_sudo_configuration() { :; }
# configure_passwordless_sudo (its marker check is the point of this
# test) is kept real; only the real-OS-account checks it depends on that
# have nothing to do with that marker logic are stubbed.
user_in_sudo_group() { :; }
passwordless_sudo_effective() { :; }
upgrade_system() { :; }
fail2ban_systemd_backend_available() { :; }
configure_ufw_before_ssh() { :; }
verify_effective_sshd_config() { :; }
verify_ssh_listener() { :; }
apply_ssh_runtime() { :; }
ufw_tcp_rule_exists() { :; }
run_final_acceptance() {
  INSTALL_STATUS="success"
  write_config_env
  atomic_write "$HGUARD_INSTALLED_MARKER" 600 "${INSTALL_STATUS}
"
}
print_final_summary() { :; }
sshd() { case "$1" in -t) return 0 ;; -T) printf 'port 22\n'; return 0 ;; *) return 0 ;; esac; }
fail2ban-client() { [ "$1" = "-t" ] && return 0; [ "$*" = "status sshd" ] && return 0; return 0; }
visudo() { return 0; }
systemctl() {
  case "$1" in
    list-unit-files) case "$2" in ssh.service|fail2ban.service) printf '%s\n' "$2"; return 0 ;; esac; return 1 ;;
    is-active|is-enabled)
      local unit="$2"; [ "$unit" = "--quiet" ] && unit="$3"
      case "$unit" in ssh.service|fail2ban.service) return 0 ;; esac
      return 1 ;;
    *) return 0 ;;
  esac
}
sysctl() {
  case "$1" in
    -n)
      case "$2" in
        net.ipv4.tcp_congestion_control) printf 'bbr\n'; return 0 ;;
        net.core.default_qdisc) printf 'fq\n'; return 0 ;;
        net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr\n'; return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 0 ;;
  esac
}
# shellcheck disable=SC2329
curl() { fail "curl must not run when every sibling file is found locally"; }
# shellcheck disable=SC2329
wget() { fail "wget must not run when every sibling file is found locally"; }

### This is the actual regression: a real main() run against this
### half-migrated state must complete successfully, not refuse with
### "unrecognized existing file" and not require the user to delete
### anything by hand first.
assert_success main

### Both previously-stale files now carry the current marker.
head -n 2 "$FAIL2BAN_JAIL" | grep -Fq 'Managed by VPSGuard' \
  && fail "the fail2ban jail still carries the old marker after a successful install run"
assert_file_contains "$FAIL2BAN_JAIL" "# Managed by Hguard"
head -n 2 "$(sudoers_file_for_user)" | grep -Fq 'Managed by VPSGuard' \
  && fail "the passwordless sudoers file still carries the old marker after a successful install run"
assert_file_contains "$(sudoers_file_for_user)" "# Managed by Hguard"

pass "a fixed installer recognizes and corrects a half-migrated marker state without refusing or requiring manual cleanup"
