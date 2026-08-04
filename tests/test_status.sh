#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_CONFIG_FILE="$temporary_root/config.env"
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

pass "status reports SSH listeners and behavior-based sudo mode details"
