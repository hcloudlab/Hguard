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
resolve_sudo_mode() { SUDO_MODE=password; }
resolve_ssh_ports() { :; }
check_root_ssh_key() { :; }
write_config_env() { :; }
upgrade_system() { rm -rf "$VPSGUARD_RUN_ROOT/sshd"; }
fail2ban_systemd_backend_available() { :; }
ensure_managed_user() { :; }
configure_authorized_keys() { :; }
configure_sudo() { :; }
verify_sudo_configuration() { :; }
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

main_output_file="$temporary_root/main-output.log"
main > "$main_output_file" 2>&1
assert_equal true "$runtime_directory_seen" "post-upgrade SSH runtime directory"
runtime_directory_mode="$(stat -c '%a' "$VPSGUARD_RUN_ROOT/sshd" 2>/dev/null || stat -f '%Lp' "$VPSGUARD_RUN_ROOT/sshd")"
assert_equal 755 "$runtime_directory_mode" "SSH runtime directory mode"
# The default install flow now applies the conntrack profile unconditionally
# (after enable_bbr, inside main() itself - see optimize_conntrack's call site),
# not only via a separate --optimize-conntrack invocation.
[ -e "$CONNTRACK_SYSCTL_FILE" ] || fail "ordinary install did not write conntrack sysctl config"
[ -e "$CONNTRACK_MODPROBE_FILE" ] || fail "ordinary install did not write conntrack modprobe config"
[ -e "$CONNTRACK_MODULES_FILE" ] || fail "ordinary install did not write conntrack modules-load config"
[ -e "$CONNTRACK_HELPER_FILE" ] || fail "ordinary install did not write conntrack helper"
[ -e "$CONNTRACK_SERVICE_FILE" ] || fail "ordinary install did not write conntrack systemd unit"

pass "OpenSSH upgrade runtime-directory recreation"

# A single main() run must report the conntrack check exactly once (it used
# to run twice - once inside optimize_conntrack, once again right after in
# main) and must never claim the pre-install snapshot was "already
# recorded" on a first install (record_preinstall_state used to run once
# explicitly in main and a second time inside optimize_conntrack).
conntrack_line_count="$(grep -c 'Conntrack usage\|Conntrack health' "$main_output_file" || true)"
assert_equal 1 "$conntrack_line_count" "the conntrack install check is reported exactly once per install"
if grep -q 'already recorded' "$main_output_file"; then
  fail "a first install must not claim the pre-install state was already recorded"
fi

pass "main() reports the conntrack check once and never claims a first install's state was already recorded"
