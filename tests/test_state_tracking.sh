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
