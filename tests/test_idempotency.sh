#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_CONFIG_FILE="$VPSGUARD_STATE_DIR/config.env"
export VPSGUARD_MANAGED_RULES="$VPSGUARD_STATE_DIR/managed-rules"
export VPSGUARD_SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config.d/00-vpsguard.conf"
export BBR_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-bbr.conf"
export BBR_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-bbr.conf"
export BBR_MODULE_PERSISTENCE_REQUIRED=true
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

NEW_USER='repeatadmin'
SSH_PORT=2222
ORIGINAL_SSH_PORT=22
INSTALL_STATUS='pending-port-finalization'

write_config_env
write_vpsguard_sshd_config true
write_bbr_files
record_managed_rule '2222/tcp'
first="$(cksum "$VPSGUARD_CONFIG_FILE" "$VPSGUARD_SSHD_CONFIG" "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$VPSGUARD_MANAGED_RULES")"

for _iteration in {1..10}; do
  write_config_env
  write_vpsguard_sshd_config true
  write_bbr_files
  record_managed_rule '2222/tcp'
done

last="$(cksum "$VPSGUARD_CONFIG_FILE" "$VPSGUARD_SSHD_CONFIG" "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$VPSGUARD_MANAGED_RULES")"
assert_equal "$first" "$last" "ten-run convergence"
pass "10 consecutive simulated runs converge without content drift"
