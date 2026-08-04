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
export VPSGUARD_SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config.d/00-vpsguard.conf"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

sshd() { [ "$1" = "-t" ] && return 0; return 1; }
SSHD_T_OUTPUT_OVERRIDE='port 2222
port 22
permitrootlogin no
passwordauthentication no
pubkeyauthentication yes'
SSH_PORT=2222
ORIGINAL_SSH_PORT=22
assert_success verify_effective_sshd_config

SSHD_T_OUTPUT_OVERRIDE='port 2222
permitrootlogin no
passwordauthentication yes
pubkeyauthentication yes'
assert_failure verify_effective_sshd_config

listener='LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
printf '%s\n' "$listener" | ssh_listener_present_from_text 2222 || fail "target listener was not recognized"
if printf '%s\n' "$listener" | ssh_listener_present_from_text 22; then
  fail "listener check used a substring port match"
fi

write_vpsguard_sshd_config true
assert_file_contains "$VPSGUARD_SSHD_CONFIG" 'Port 2222'
assert_file_contains "$VPSGUARD_SSHD_CONFIG" 'Port 22'
write_vpsguard_sshd_config false
assert_file_contains "$VPSGUARD_SSHD_CONFIG" 'Port 2222'
if grep -Fxq 'Port 22' "$VPSGUARD_SSHD_CONFIG"; then
  fail "old port remained after explicit finalization"
fi

mock_socket_present=true
systemctl() {
  case "$*" in
    'list-unit-files ssh.socket --no-legend') [ "$mock_socket_present" = true ] && printf 'ssh.socket enabled\n' ;;
    'list-unit-files ssh.service --no-legend') printf 'ssh.service enabled\n' ;;
    'list-unit-files sshd.service --no-legend') return 0 ;;
    'is-active --quiet ssh.socket') [ "$mock_socket_present" = true ] ;;
    'is-enabled --quiet ssh.socket') [ "$mock_socket_present" = true ] ;;
    *) return 1 ;;
  esac
}
detect_ssh_runtime_mode
assert_equal socket "$SSH_RUNTIME_MODE" "socket runtime detection"
mock_socket_present=false
detect_ssh_runtime_mode
assert_equal service "$SSH_RUNTIME_MODE" "service runtime detection without ssh.socket"

pass "SSH effective configuration, listener, socket mode and old-port staging"
