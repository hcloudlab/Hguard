#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export BBR_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-bbr.conf"
export BBR_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-bbr.conf"
export BBR_MODULE_PERSISTENCE_REQUIRED=true
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

assert_equal already-enabled "$(classify_bbr_state 'reno cubic bbr' bbr fq)" "already enabled"
assert_equal enabled "$(classify_bbr_state 'reno cubic bbr' cubic fq)" "module or built-in support"
assert_equal unsupported "$(classify_bbr_state 'reno cubic' cubic fq)" "unsupported kernel"
assert_equal failed "$(classify_bbr_state 'reno cubic bbr' cubic fq true)" "sysctl failure"

write_bbr_files
first_sysctl="$(checksum_file "$BBR_SYSCTL_FILE")"
first_modules="$(checksum_file "$BBR_MODULES_FILE")"
write_bbr_files
assert_equal "$first_sysctl" "$(checksum_file "$BBR_SYSCTL_FILE")" "sysctl checksum"
assert_equal "$first_modules" "$(checksum_file "$BBR_MODULES_FILE")" "modules checksum"
assert_equal 1 "$(grep -c '^net.ipv4.tcp_congestion_control = bbr$' "$BBR_SYSCTL_FILE")" "single BBR line"
assert_equal 1 "$(grep -c '^tcp_bbr$' "$BBR_MODULES_FILE")" "single module line"

pass "BBR state classification and idempotent managed files"
