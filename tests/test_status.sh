#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_PROC_ROOT="$temporary_root/proc"
export VPSGUARD_PROC_SYS_ROOT="$temporary_root/proc/sys"
export VPSGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_CONFIG_FILE="$temporary_root/config.env"
export CONNTRACK_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-conntrack.conf"
export CONNTRACK_MODPROBE_FILE="$temporary_root/etc/modprobe.d/vpsguard-nf-conntrack.conf"
export CONNTRACK_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-conntrack.conf"
export CONNTRACK_HELPER_FILE="$temporary_root/etc/vpsguard/apply-conntrack-profile.sh"
export CONNTRACK_SERVICE_FILE="$temporary_root/etc/systemd/system/vpsguard-conntrack.service"
export VPSGUARD_CONNTRACK_LOG_TEXT=""
# shellcheck source=status.sh
. "$TEST_ROOT/status.sh"

printf "NEW_USER='statusadmin'\nINSTALL_STATUS='failed'\n" > "$VPSGUARD_CONFIG_FILE"
assert_equal unverified "$(configured_sudo_mode)" "missing SUDO_MODE is unverified"
printf "SUDO_MODE='password'\n" >> "$VPSGUARD_CONFIG_FILE"
assert_equal password "$(configured_sudo_mode)" "validated password mode"
printf "SUDO_MODE='pending'\n" > "$VPSGUARD_CONFIG_FILE"
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

mkdir -p "$VPSGUARD_PROC_SYS_ROOT/net/netfilter" "$VPSGUARD_SYS_MODULE_ROOT/nf_conntrack/parameters"
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
printf '# Managed by VPSGuard 0.3.6\n' > "$CONNTRACK_SYSCTL_FILE"
drift_output="$(print_conntrack_status)"
printf '%s\n' "$drift_output" | grep -Fq 'Runtime profile: drift detected' || fail "status conntrack drift output is missing"
printf '%s\n' "$drift_output" | grep -Fq "rerun 'sudo bash install.sh --optimize-conntrack'" || fail "status conntrack drift redeploy hint is missing"
mkdir -p "$(dirname "$CONNTRACK_SERVICE_FILE")" "$(dirname "$CONNTRACK_HELPER_FILE")"
printf '# Managed by VPSGuard 0.3.6\n[Service]\nType=oneshot\n' > "$CONNTRACK_SERVICE_FILE"
printf '# Managed by VPSGuard 0.3.6\n' > "$CONNTRACK_HELPER_FILE"
restart_hint_output="$(print_conntrack_status)"
printf '%s\n' "$restart_hint_output" | grep -Fq "sudo systemctl restart vpsguard-conntrack.service" || fail "status conntrack drift restart hint is missing"
printf '65536\n' > "$(conntrack_max_file)"
printf '16384\n' > "$(conntrack_hashsize_file)"
printf '30\n' > "$(conntrack_timeout_file syn_sent)"
printf '20\n' > "$(conntrack_timeout_file syn_recv)"
printf '30\n' > "$(conntrack_timeout_file time_wait)"
active_output="$(print_conntrack_status)"
printf '%s\n' "$active_output" | grep -Fq 'Runtime profile: active' || fail "status conntrack active runtime profile is missing"
VPSGUARD_CONNTRACK_LOG_TEXT='nf_conntrack: table full, dropping packet'
critical_output="$(print_conntrack_status)"
printf '%s\n' "$critical_output" | grep -Fq 'Health: CRITICAL' || fail "status conntrack table-full output is missing"
printf '%s\n' "$critical_output" | grep -Fq 'Linux has dropped packets' || fail "status conntrack warning is missing"

pass "status reports SSH listeners, behavior-based sudo mode details and conntrack health"
