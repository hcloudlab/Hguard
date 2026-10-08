#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_STATE_FILE="$VPSGUARD_STATE_DIR/state.env"
export VPSGUARD_MANAGED_RULES="$VPSGUARD_STATE_DIR/managed-rules"
export VPSGUARD_SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config.d/00-vpsguard.conf"
export FAIL2BAN_JAIL="$temporary_root/etc/fail2ban/jail.d/vpsguard-sshd.local"
export BBR_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-bbr.conf"
export BBR_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-bbr.conf"
export CONNTRACK_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-conntrack.conf"
export CONNTRACK_MODPROBE_FILE="$temporary_root/etc/modprobe.d/vpsguard-nf-conntrack.conf"
export CONNTRACK_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-conntrack.conf"
export CONNTRACK_HELPER_FILE="$temporary_root/etc/vpsguard/apply-conntrack-profile.sh"
export CONNTRACK_SERVICE_FILE="$temporary_root/etc/systemd/system/vpsguard-conntrack.service"
export VPSGUARD_RUN_ROOT="$temporary_root/run"
mkdir -p "$VPSGUARD_RUN_ROOT"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

ufw() { printf 'Status: inactive\n'; }
systemctl() { return 1; }
record_preinstall_state
first_state="$(checksum_file "$VPSGUARD_STATE_FILE")"
record_preinstall_state
assert_equal "$first_state" "$(checksum_file "$VPSGUARD_STATE_FILE")" "original state snapshot"
assert_file_contains "$VPSGUARD_STATE_FILE" "CONNTRACK_SYSCTL_PREEXISTED='false'"
assert_file_contains "$VPSGUARD_STATE_FILE" "CONNTRACK_MODPROBE_PREEXISTED='false'"
assert_file_contains "$VPSGUARD_STATE_FILE" "CONNTRACK_MODULES_PREEXISTED='false'"
assert_file_contains "$VPSGUARD_STATE_FILE" "CONNTRACK_HELPER_PREEXISTED='false'"
assert_file_contains "$VPSGUARD_STATE_FILE" "CONNTRACK_SERVICE_PREEXISTED='false'"

record_managed_rule '22/tcp'
record_managed_rule '22/tcp'
assert_equal 1 "$(grep -c '^22/tcp$' "$VPSGUARD_MANAGED_RULES")" "managed rule uniqueness"

pass "pre-install state is immutable and managed rules are unique"

# print_final_summary must report the server IP from `hostname -I` only, with
# no external network call.
curl() { fail "print_final_summary must not call curl/network for the server IP"; }
# Called indirectly by print_final_summary.
# shellcheck disable=SC2329
hostname() { [ "$1" = "-I" ] && printf '203.0.113.5 fe80::1\n'; }
NEW_USER="admin"
SUDO_MODE="passwordless"
SSH_PORT=22
ORIGINAL_SSH_PORT=22
SSH_RUNTIME_MODE="socket"
BBR_STATUS="enabled"
INSTALL_STATUS="success"
summary_output="$(print_final_summary)"
assert_file_contains /dev/stdin "203.0.113.5" <<<"$summary_output"

pass "print_final_summary reports the server IP from hostname -I only, no network call"

# is_private_ipv4: RFC 1918 + RFC 6598 (carrier-grade NAT, used by AWS/GCP
# VPCs) ranges and their boundaries.
assert_success is_private_ipv4 10.0.0.1
assert_success is_private_ipv4 172.16.0.1
assert_success is_private_ipv4 172.31.255.254
assert_success is_private_ipv4 192.168.1.1
assert_success is_private_ipv4 100.64.0.1
assert_success is_private_ipv4 100.127.255.255
assert_failure is_private_ipv4 172.15.255.255
assert_failure is_private_ipv4 172.32.0.1
assert_failure is_private_ipv4 100.63.255.255
assert_failure is_private_ipv4 100.128.0.1
assert_failure is_private_ipv4 203.0.113.5
assert_failure is_private_ipv4 8.8.8.8

pass "is_private_ipv4 covers RFC 1918 and RFC 6598 ranges and their boundaries"

# A cloud VPC's private address (e.g. AWS's 172.31.x.x) must be hidden
# behind the SERVER_IP placeholder, with a hint to use the console's public
# IP instead - this is the exact AWS scenario found in testing.
# Called indirectly by print_final_summary.
# shellcheck disable=SC2329
hostname() { [ "$1" = "-I" ] && printf '172.31.5.20 fe80::1\n'; }
summary_output="$(print_final_summary)"
assert_file_contains /dev/stdin 'ssh -p 22 admin@SERVER_IP' <<<"$summary_output"
assert_file_contains /dev/stdin '172.31.5.20' <<<"$summary_output"
if printf '%s\n' "$summary_output" | grep -Fq 'admin@172.31.5.20'; then
  fail "a private VPC IP must not be printed as the ssh target"
fi

pass "print_final_summary hides a private VPC IP behind SERVER_IP with a console hint"

# /run/reboot-required must trigger a warning so the operator knows to
# reboot manually after verifying the new admin can log in - the script
# must never reboot on its own.
hostname() { [ "$1" = "-I" ] && printf '203.0.113.5 fe80::1\n'; }
summary_output="$(print_final_summary)"
if printf '%s\n' "$summary_output" | grep -q '重启'; then
  fail "no reboot warning should be printed when /run/reboot-required is absent"
fi

: > "$VPSGUARD_RUN_ROOT/reboot-required"
summary_output="$(print_final_summary)"
assert_file_contains /dev/stdin '系统更新需要重启才能完全生效' <<<"$summary_output"
rm -f "$VPSGUARD_RUN_ROOT/reboot-required"

pass "print_final_summary warns when /run/reboot-required exists, without rebooting"
