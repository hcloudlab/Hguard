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
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

ufw() { printf 'Status: inactive\n'; }
systemctl() { return 1; }
record_preinstall_state
first_state="$(checksum_file "$VPSGUARD_STATE_FILE")"
record_preinstall_state
assert_equal "$first_state" "$(checksum_file "$VPSGUARD_STATE_FILE")" "original state snapshot"

record_managed_rule '22/tcp'
record_managed_rule '22/tcp'
assert_equal 1 "$(grep -c '^22/tcp$' "$VPSGUARD_MANAGED_RULES")" "managed rule uniqueness"

pass "pre-install state is immutable and managed rules are unique"
