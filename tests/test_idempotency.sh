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
export CONNTRACK_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-vpsguard-conntrack.conf"
export CONNTRACK_MODPROBE_FILE="$temporary_root/etc/modprobe.d/vpsguard-nf-conntrack.conf"
export CONNTRACK_MODULES_FILE="$temporary_root/etc/modules-load.d/vpsguard-conntrack.conf"
export CONNTRACK_HELPER_FILE="$temporary_root/etc/vpsguard/apply-conntrack-profile.sh"
export CONNTRACK_SERVICE_FILE="$temporary_root/etc/systemd/system/vpsguard-conntrack.service"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

NEW_USER='repeatadmin'
SUDO_MODE='password'
SSH_PORT=2222
ORIGINAL_SSH_PORT=22
INSTALL_STATUS='pending-port-finalization'

write_config_env
write_vpsguard_sshd_config true
write_bbr_files
write_conntrack_files 16384
record_managed_rule '2222/tcp'
first="$(cksum "$VPSGUARD_CONFIG_FILE" "$VPSGUARD_SSHD_CONFIG" "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE" "$VPSGUARD_MANAGED_RULES")"
assert_equal password "$(read_env_value "$VPSGUARD_CONFIG_FILE" SUDO_MODE)" "persisted sudo mode"

for _iteration in {1..10}; do
  write_config_env
  write_vpsguard_sshd_config true
  write_bbr_files
  write_conntrack_files 16384
  record_managed_rule '2222/tcp'
done

last="$(cksum "$VPSGUARD_CONFIG_FILE" "$VPSGUARD_SSHD_CONFIG" "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE" "$VPSGUARD_MANAGED_RULES")"
assert_equal "$first" "$last" "ten-run convergence"
pass "10 consecutive simulated runs converge without content drift"

temporary_root2="$(mktemp -d)"
trap 'rm -rf "$temporary_root2"' EXIT
target_file="$temporary_root2/managed.conf"

atomic_write "$target_file" 644 'hello'
assert_equal "true" "$ATOMIC_WRITE_CHANGED" "first write to a new path sets ATOMIC_WRITE_CHANGED=true"

atomic_write "$target_file" 644 'hello'
assert_equal "false" "$ATOMIC_WRITE_CHANGED" "rewriting identical content sets ATOMIC_WRITE_CHANGED=false"

atomic_write "$target_file" 644 'hello again'
assert_equal "true" "$ATOMIC_WRITE_CHANGED" "rewriting different content sets ATOMIC_WRITE_CHANGED=true"

# The real regression this guards against: under set -euo pipefail, calling
# atomic_write on unchanged content must NOT abort the script. Run this in a
# fresh subshell with its own set -e so a non-zero return from atomic_write
# would actually be caught, unlike the sourcing shell which may have laxer
# settings by the time tests run.
marker_file="$temporary_root2/reached-after-unchanged-write"
rm -f "$marker_file"
(
  set -euo pipefail
  . "$TEST_ROOT/install-core.sh"
  atomic_write "$target_file" 644 'hello again'   # already on disk from above: unchanged
  touch "$marker_file"
)
[ -f "$marker_file" ] || fail "script execution stopped after atomic_write hit unchanged content under set -e"

pass "atomic_write reports change via ATOMIC_WRITE_CHANGED without ever failing on unchanged content"
