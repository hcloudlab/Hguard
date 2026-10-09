#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_PROC_SYS_ROOT="$temporary_root/proc/sys"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_CONFIG_FILE="$temporary_root/config.env"
export CONNTRACK_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-hguard-conntrack.conf"
export CONNTRACK_MODPROBE_FILE="$temporary_root/etc/modprobe.d/hguard-nf-conntrack.conf"
export CONNTRACK_MODULES_FILE="$temporary_root/etc/modules-load.d/hguard-conntrack.conf"
export CONNTRACK_HELPER_FILE="$temporary_root/etc/hguard/apply-conntrack-profile.sh"
export CONNTRACK_SERVICE_FILE="$temporary_root/etc/systemd/system/hguard-conntrack.service"
export HGUARD_CONNTRACK_LOG_TEXT=""
# shellcheck source=status.sh
. "$TEST_ROOT/status.sh"

printf "NEW_USER='statusadmin'\nINSTALL_STATUS='failed'\n" > "$HGUARD_CONFIG_FILE"
assert_equal unverified "$(configured_sudo_mode)" "missing SUDO_MODE is unverified"
printf "SUDO_MODE='password'\n" >> "$HGUARD_CONFIG_FILE"
assert_equal password "$(configured_sudo_mode)" "validated password mode"
printf "SUDO_MODE='pending'\n" > "$HGUARD_CONFIG_FILE"
assert_equal invalid "$(configured_sudo_mode)" "invalid SUDO_MODE is not inferred"

effective_sshd='port 2222
port 2222
permitrootlogin no'
assert_equal 2222 "$(sshd_ports "$effective_sshd")" "deduplicated effective SSH ports"

effective_socket_listeners='0.0.0.0:2222 (Stream)
[::]:2222 (Stream)
0.0.0.0:2222 (Stream)'
actual_listeners="$(printf '%s\n' "$effective_socket_listeners" | systemd_socket_listeners_from_text)"
assert_equal '0.0.0.0:2222,[::]:2222' "$actual_listeners" "effective systemd socket listeners"
assert_equal none "$(printf '' | systemd_socket_listeners_from_text)" "empty systemd socket listeners"
assert_equal '0.0.0.0:2222,[::]:2222' \
  "$(printf '%s\n' "$effective_socket_listeners" | systemd_socket_listeners_for_state_from_text active)" \
  "active systemd socket reports effective listeners"
assert_equal inactive \
  "$(printf '[::]:22 (Stream)\n' | systemd_socket_listeners_for_state_from_text inactive)" \
  "inactive systemd socket does not report configured port as a listener"


listener_22='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
listener_2222='LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))'
listeners_both="${listener_22}"$'\n'"${listener_2222}"

# Real `ss -ltnpH` output (TCP only - no Netid column) and real `ss -ltnupH`
# output (TCP+UDP - has a Netid column) captured on an AWS Ubuntu 24.04
# instance, both on port 22. ssh_listener_present must recognize the
# listener in either format without assuming a fixed column index.
no_netid_listener_22='LISTEN 0      4096                0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=24473,fd=3),("systemd",pid=1,fd=143))
LISTEN 0      4096                   [::]:22       [::]:*  users:(("sshd",pid=24473,fd=4),("systemd",pid=1,fd=144))'
assert_success ssh_listener_present 22 "$no_netid_listener_22"

with_netid_listener_22='tcp LISTEN 0      4096                0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=24473,fd=3),("systemd",pid=1,fd=143))'
assert_success ssh_listener_present 22 "$with_netid_listener_22"

assert_equal not-started \
  "$(port_finalization_state 2222 22 "$listener_22" missing missing)" \
  "fresh pre-SSH failure is not started"

assert_equal pending \
  "$(port_finalization_state 2222 22 "$listeners_both" present present)" \
  "dual-port migration with marker is pending"

assert_equal complete \
  "$(port_finalization_state 2222 22 "$listener_2222" present missing)" \
  "finalized target listener is complete"

assert_equal incomplete \
  "$(port_finalization_state 2222 22 "$listeners_both" present missing)" \
  "old listener without pending marker is incomplete"

assert_equal incomplete \
  "$(port_finalization_state 2222 22 '' present missing)" \
  "missing target listener is incomplete"

passwordless_behavior="true"
# Called indirectly by passwordless_sudo_effective_for_user below, and
# later shadowed by another stub further down in this file.
# shellcheck disable=SC2317,SC2329
sudo() {
  case "$*" in
    '-u statusadmin sudo -k') return 0 ;;
    '-u statusadmin sudo -n true'|'-u statusadmin sudo -n -i true') [ "$passwordless_behavior" = "true" ] ;;
    *) return 1 ;;
  esac
}
assert_success passwordless_sudo_effective_for_user statusadmin
passwordless_behavior="false"
assert_failure passwordless_sudo_effective_for_user statusadmin

assert_file_contains "$TEST_ROOT/status.sh" 'Sudo mode: %s'
assert_file_contains "$TEST_ROOT/status.sh" 'Password state: %s'
assert_file_contains "$TEST_ROOT/status.sh" 'Sudo group membership: %s'
assert_file_contains "$TEST_ROOT/status.sh" 'Managed sudoers file: present'
assert_file_contains "$TEST_ROOT/status.sh" 'visudo validation: valid'
assert_file_contains "$TEST_ROOT/status.sh" 'Passwordless sudo effective: %s'
assert_file_contains "$TEST_ROOT/status.sh" 'No sudo mode has completed validation'
assert_file_contains "$TEST_ROOT/status.sh" 'configuration and actual behavior are inconsistent'

mkdir -p "$HGUARD_PROC_SYS_ROOT/net/netfilter" "$HGUARD_SYS_MODULE_ROOT/nf_conntrack/parameters"
printf '100\n' > "$(conntrack_count_file)"
printf '32768\n' > "$(conntrack_max_file)"
printf '8192\n' > "$(conntrack_hashsize_file)"
printf '120\n' > "$(conntrack_timeout_file syn_sent)"
printf '60\n' > "$(conntrack_timeout_file syn_recv)"
printf '120\n' > "$(conntrack_timeout_file time_wait)"
assert_equal OK "$(classify_conntrack_health 100 32768 no)" "status conntrack OK classification"
conntrack_output="$(print_conntrack_status)"
printf '%s\n' "$conntrack_output" | grep -Fq 'Usage: 100 / 32768 (0.3%)' || fail "status conntrack usage output is missing"
printf '%s\n' "$conntrack_output" | grep -Fq 'Table exhaustion found in accessible kernel logs: no' || fail "status conntrack accessible-log label is missing"
printf '%s\n' "$conntrack_output" | grep -Fq 'Runtime profile: not configured' || fail "status conntrack unconfigured runtime profile is missing"
printf '%s\n' "$conntrack_output" | grep -Fq 'Health: OK' || fail "status conntrack health output is missing"
mkdir -p "$(dirname "$CONNTRACK_SYSCTL_FILE")"
printf '# Managed by Hguard 0.3.6\n' > "$CONNTRACK_SYSCTL_FILE"
drift_output="$(print_conntrack_status)"
printf '%s\n' "$drift_output" | grep -Fq 'Runtime profile: drift detected' || fail "status conntrack drift output is missing"
printf '%s\n' "$drift_output" | grep -Fq "rerun 'sudo bash install.sh --optimize-conntrack'" || fail "status conntrack drift redeploy hint is missing"
mkdir -p "$(dirname "$CONNTRACK_SERVICE_FILE")" "$(dirname "$CONNTRACK_HELPER_FILE")"
printf '# Managed by Hguard 0.3.6\n[Service]\nType=oneshot\n' > "$CONNTRACK_SERVICE_FILE"
printf '# Managed by Hguard 0.3.6\n' > "$CONNTRACK_HELPER_FILE"
restart_hint_output="$(print_conntrack_status)"
printf '%s\n' "$restart_hint_output" | grep -Fq "sudo systemctl restart hguard-conntrack.service" || fail "status conntrack drift restart hint is missing"
printf '65536\n' > "$(conntrack_max_file)"
printf '16384\n' > "$(conntrack_hashsize_file)"
printf '30\n' > "$(conntrack_timeout_file syn_sent)"
printf '20\n' > "$(conntrack_timeout_file syn_recv)"
printf '30\n' > "$(conntrack_timeout_file time_wait)"
active_output="$(print_conntrack_status)"
printf '%s\n' "$active_output" | grep -Fq 'Runtime profile: active' || fail "status conntrack active runtime profile is missing"
HGUARD_CONNTRACK_LOG_TEXT='nf_conntrack: table full, dropping packet'
critical_output="$(print_conntrack_status)"
printf '%s\n' "$critical_output" | grep -Fq 'Health: CRITICAL' || fail "status conntrack table-full output is missing"
printf '%s\n' "$critical_output" | grep -Fq 'Linux has dropped packets' || fail "status conntrack warning is missing"

apt-cache() {
  [ "$1" = "policy" ] || return 1
  case "$2" in
    sudo) printf 'sudo:\n  Installed: 1.0\n  Candidate: 2.0\n' ;;
    *) printf '%s:\n  Installed: (none)\n  Candidate: 1.0\n' "$2" ;;
  esac
}
components_output="$(print_managed_components_status)"
printf '%s\n' "$components_output" | grep -Fq 'sudo: 1.0 (upgradable to 2.0)' || fail "upgradable managed component is not reported"
printf '%s\n' "$components_output" | grep -Fq 'ufw: not installed' || fail "a not-installed managed component is not reported"
printf '%s\n' "$components_output" | grep -Fq 'Last apt-hook verification: never run' || fail "missing apt-hook state should report never run"

mkdir -p "$(dirname "$HGUARD_APT_HOOK_STATE_FILE")"
printf "TIMESTAMP='2026-10-08T00:00:00Z'\nRESULT='PASS'\n" > "$HGUARD_APT_HOOK_STATE_FILE"
components_output="$(print_managed_components_status)"
printf '%s\n' "$components_output" | grep -Fq 'Last apt-hook verification: PASS (2026-10-08T00:00:00Z)' || fail "recorded apt-hook verification result is not reported"

pass "status reports each managed component's version and the apt hook's last verification result"

### D3: a VPSGuard-managed file reappearing after migration (e.g. the old
### 0.3.7 installer run again) must be warned about loudly, listing every
### one found, and never removed.
assert_equal "" "$(legacy_vpsguard_files_present)" "no legacy VPSGuard files present yet"
mkdir -p "$(dirname "$VPSGUARD_LEGACY_FAIL2BAN_JAIL")"
printf '# Managed by VPSGuard 0.3.7\n[sshd]\n' > "$VPSGUARD_LEGACY_FAIL2BAN_JAIL"
assert_equal "$VPSGUARD_LEGACY_FAIL2BAN_JAIL" "$(legacy_vpsguard_files_present)" "a reappeared legacy file is detected"

warning_output="$(print_legacy_vpsguard_warning)"
printf '%s\n' "$warning_output" | grep -Fq "$VPSGUARD_LEGACY_FAIL2BAN_JAIL" || fail "the warning must list the reappeared file's path"
[ -f "$VPSGUARD_LEGACY_FAIL2BAN_JAIL" ] || fail "print_legacy_vpsguard_warning must never remove anything"

rm -f "$VPSGUARD_LEGACY_FAIL2BAN_JAIL"
assert_equal "" "$(print_legacy_vpsguard_warning)" "no warning once the legacy file is gone"

pass "status warns (without removing anything) when a VPSGuard-managed file reappears after migration"

pass "status reports SSH listeners, behavior-based sudo mode details and conntrack health"

### Item 5: on an ssh.service-mode machine, "Managed ssh.socket override:
### missing" reads like something is wrong, when a socket override was
### never applicable there to begin with. Must say so instead of
### "missing".
printf "NEW_USER='statusadmin'\nSSH_PORT='22'\nORIGINAL_SSH_PORT='22'\nSUDO_MODE='password'\nINSTALL_STATUS='success'\n" > "$HGUARD_CONFIG_FILE"
id() { [ "${1:-}" = "-u" ] && printf '0\n' || return 0; }
getent() { return 2; }
sshd() { case "$1" in -t) return 0 ;; -T) printf 'port 22\npermitrootlogin no\npasswordauthentication no\npubkeyauthentication yes\n'; return 0 ;; *) return 0 ;; esac; }
ss() { return 0; }
ufw() { [ "$1" = status ] && printf 'Status: active\n22/tcp ALLOW Anywhere\n'; }
fail2ban-client() { return 0; }
sysctl() { return 0; }
hostname() { printf 'statustest\n'; }
visudo() { return 0; }
# Called indirectly by main()'s passwordless_sudo_effective_for_user.
# shellcheck disable=SC2329
sudo() { return 1; }
passwd() { return 1; }
apt-cache() { [ "$1" = policy ] || return 1; printf '%s:\n  Installed: 1.0\n  Candidate: 1.0\n' "$2"; }

# ssh.service mode: ssh.socket is not active (not-found).
systemctl() {
  case "$1" in
    is-active) return 1 ;;
    list-unit-files) [ "$2" = "ssh.service" ] && printf 'ssh.service\n'; return 0 ;;
    *) return 0 ;;
  esac
}
service_mode_output="$(main)"
printf '%s\n' "$service_mode_output" | grep -Fq 'Managed ssh.socket override: not applicable (ssh.service mode)' \
  || fail "ssh.service mode must report the socket override as not applicable, not missing"

# ssh.socket mode: ssh.socket is active.
systemctl() {
  case "$1" in
    is-active) [ "$2" = "--quiet" ] && [ "$3" = "ssh.socket" ] && return 0; return 1 ;;
    list-unit-files) [ "$2" = "ssh.socket" ] && printf 'ssh.socket\n'; return 0 ;;
    *) return 0 ;;
  esac
}
socket_mode_output="$(main)"
printf '%s\n' "$socket_mode_output" | grep -Fq 'Managed ssh.socket override: missing' \
  || fail "ssh.socket mode must still report present/missing for the socket override"
if printf '%s\n' "$socket_mode_output" | grep -Fq 'not applicable'; then
  fail "ssh.socket mode must not report the socket override as not applicable"
fi

pass "status reports the ssh.socket override as not applicable in ssh.service mode instead of a misleading 'missing'"
