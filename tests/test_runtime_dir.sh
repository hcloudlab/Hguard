#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_RUN_ROOT="$temporary_root/run"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

require_root() { :; }
check_ubuntu_lts() { :; }
resolve_managed_user() { :; }
resolve_ssh_ports() { :; }
write_config_env() { :; }
record_preinstall_state() { :; }
upgrade_system() { rm -rf "$VPSGUARD_RUN_ROOT/sshd"; }
ensure_managed_user() { :; }
configure_authorized_keys() { :; }
configure_sudo() { :; }
verify_sudo_configuration() { :; }
confirm_sudo_password_authentication() { :; }
configure_ufw_before_ssh() { :; }
runtime_directory_seen=false
configure_ssh_safely() {
  if [ -d "$VPSGUARD_RUN_ROOT/sshd" ]; then
    runtime_directory_seen=true
  fi
}
configure_fail2ban() { :; }
enable_bbr() { :; }
run_final_acceptance() { :; }
remove_legacy_phase_markers() { :; }
print_final_summary() { :; }

main
assert_equal true "$runtime_directory_seen" "post-upgrade SSH runtime directory"
runtime_directory_mode="$(stat -c '%a' "$VPSGUARD_RUN_ROOT/sshd" 2>/dev/null || stat -f '%Lp' "$VPSGUARD_RUN_ROOT/sshd")"
assert_equal 755 "$runtime_directory_mode" "SSH runtime directory mode"

pass "OpenSSH upgrade runtime-directory recreation"
