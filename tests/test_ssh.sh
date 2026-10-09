#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_CONFIG_FILE="$HGUARD_STATE_DIR/config.env"
export SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config"
export HGUARD_SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config.d/00-hguard.conf"
export HGUARD_SSH_SOCKET_OVERRIDE="$temporary_root/etc/systemd/system/ssh.socket.d/00-hguard.conf"
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

# Real `ss -ltnpH` output (TCP only - no Netid column) and real `ss -ltnupH`
# output (TCP+UDP - has a Netid column) captured on an AWS Ubuntu 24.04
# instance, both on port 22. ssh_listener_present_from_text must recognize
# the listener in either format without assuming a fixed column index.
no_netid_listener='LISTEN 0      4096                0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=24473,fd=3),("systemd",pid=1,fd=143))
LISTEN 0      4096                   [::]:22       [::]:*  users:(("sshd",pid=24473,fd=4),("systemd",pid=1,fd=144))'
printf '%s\n' "$no_netid_listener" | ssh_listener_present_from_text 22 \
  || fail "target listener was not recognized in real ss -ltnpH (no Netid column) output"

with_netid_listener='tcp LISTEN 0      4096                0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=24473,fd=3),("systemd",pid=1,fd=143))'
printf '%s\n' "$with_netid_listener" | ssh_listener_present_from_text 22 \
  || fail "target listener was not recognized in real ss -ltnupH (with Netid column) output"

write_hguard_sshd_config true
assert_file_contains "$HGUARD_SSHD_CONFIG" 'Port 2222'
assert_file_contains "$HGUARD_SSHD_CONFIG" 'Port 22'
write_hguard_sshd_config false
assert_file_contains "$HGUARD_SSHD_CONFIG" 'Port 2222'
if grep -Fxq 'Port 22' "$HGUARD_SSHD_CONFIG"; then
  fail "old port remained after explicit finalization"
fi

mkdir -p "$(dirname "$SSHD_CONFIG")"
printf 'PermitRootLogin prohibit-password\nInclude /etc/ssh/sshd_config.d/*.conf\n' > "$SSHD_CONFIG"
ensure_hguard_sshd_include_first
assert_equal '# BEGIN Hguard managed include' "$(sed -n '1p' "$SSHD_CONFIG")" "Hguard include must precede vendor policy"
assert_equal "Include ${HGUARD_SSHD_CONFIG}" "$(sed -n '2p' "$SSHD_CONFIG")" "Hguard exact include path"
assert_equal 1 "$(grep -Fc '# BEGIN Hguard managed include' "$SSHD_CONFIG")" "managed include uniqueness"
ensure_hguard_sshd_include_first
assert_equal 1 "$(grep -Fc '# BEGIN Hguard managed include' "$SSHD_CONFIG")" "managed include rerun uniqueness"

write_hguard_ssh_socket_override true
assert_file_contains "$HGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream='
assert_file_contains "$HGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream=0.0.0.0:2222'
assert_file_contains "$HGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream=0.0.0.0:22'
write_hguard_ssh_socket_override false
if grep -Fxq 'ListenStream=0.0.0.0:22' "$HGUARD_SSH_SOCKET_OVERRIDE"; then
  fail "old socket port remained after explicit finalization"
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
# A subshell, not a direct call: this file later redefines detect_ssh_
# runtime_mode as a hardcoded stub for a different scenario, and an
# earlier call to the real function parsed together with that later
# redefinition of the same name is exactly the shape the SC2218 check
# ("this function is only defined later") flags. $SSH_RUNTIME_MODE
# doesn't escape a subshell, so it's captured to a file instead.
detected_runtime_mode_file="$temporary_root/detected-runtime-mode"
( detect_ssh_runtime_mode; printf '%s\n' "$SSH_RUNTIME_MODE" > "$detected_runtime_mode_file" )
assert_equal socket "$(cat "$detected_runtime_mode_file")" "socket runtime detection"
mock_socket_present=false
( detect_ssh_runtime_mode; printf '%s\n' "$SSH_RUNTIME_MODE" > "$detected_runtime_mode_file" )
assert_equal service "$(cat "$detected_runtime_mode_file")" "service runtime detection without ssh.socket"

pass "SSH effective configuration, first-include policy, socket listeners and old-port staging"

NEW_USER="symlinkadmin"
export ROOT_AUTHORIZED_KEYS="$temporary_root/root-authorized_keys"
# check_root_ssh_key really parses this with ssh-keygen, so a fake-looking
# string (e.g. "ssh-ed25519 AAAA root@host") fails for the wrong reason - it
# must be a real key.
ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/root_test_key" </dev/null
cp "$temporary_root/root_test_key.pub" "$ROOT_AUTHORIZED_KEYS"
fake_user_home="$temporary_root/home/symlinkadmin"
managed_user_home() { printf '%s\n' "$fake_user_home"; }

mkdir -p "$fake_user_home"
real_target="$(mktemp -d)"
rm -rf "$fake_user_home/.ssh"
ln -s "$real_target" "$fake_user_home/.ssh"
# configure_authorized_keys calls error(), which exits the process on a
# symlink rejection - run it in a subshell to check the exit status without
# killing this whole test script.
if (configure_authorized_keys) 2>/dev/null; then
  fail "configure_authorized_keys should refuse a symlinked ~/.ssh"
fi
rm -f "$fake_user_home/.ssh"

mkdir -p "$fake_user_home/.ssh"
ln -s /dev/null "$fake_user_home/.ssh/authorized_keys"
if (configure_authorized_keys) 2>/dev/null; then
  fail "configure_authorized_keys should refuse a symlinked authorized_keys"
fi

pass "configure_authorized_keys refuses a symlinked ~/.ssh or authorized_keys"

# configure_ssh_safely must only restart/reload SSH when the policy actually
# changed - real atomic_write change-detection drives this, not a stub.
mkdir -p "$(dirname "$SSHD_CONFIG")"
printf 'Port 22\n' > "$SSHD_CONFIG"
detect_ssh_runtime_mode() { SSH_RUNTIME_MODE="service"; SSH_SERVICE_UNIT="ssh.service"; }
verify_effective_sshd_config() { return 0; }
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2317,SC2329
verify_ssh_listener() { return 0; }
ufw_tcp_rule_exists() { return 0; }
apply_runtime_count=0
listener_up="true"
apply_ssh_runtime() { apply_runtime_count=$((apply_runtime_count + 1)); listener_up="true"; return 0; }
verify_ssh_listener() { [ "$listener_up" = "true" ]; }

SSH_PORT=2222
ORIGINAL_SSH_PORT=2222
PORT_MIGRATION_REQUIRED=false

configure_ssh_safely
assert_equal 1 "$apply_runtime_count" "first run with new policy content applies the SSH runtime"

configure_ssh_safely
assert_equal 1 "$apply_runtime_count" "rerun with unchanged policy content does not reapply the SSH runtime"

# Policy content still unchanged, but the target port has stopped listening
# (e.g. sshd crashed or was restarted externally) - must still reapply.
listener_up="false"
configure_ssh_safely
assert_equal 2 "$apply_runtime_count" "unchanged policy content but target port not listening still reapplies the SSH runtime"

pass "configure_ssh_safely reapplies when the SSH runtime is unhealthy, even if the policy content is unchanged"

export HGUARD_PROC_ROOT="$temporary_root/proc"
mkdir -p "$HGUARD_PROC_ROOT/net"
rm -f "$HGUARD_PROC_ROOT/net/if_inet6"  # IPv6 unavailable
SSH_PORT=22
HGUARD_SSH_SOCKET_OVERRIDE="$temporary_root/etc/systemd/system/ssh.socket.d/01-hguard.conf"
write_hguard_ssh_socket_override false
assert_file_contains "$HGUARD_SSH_SOCKET_OVERRIDE" "0.0.0.0:22"
if grep -q '::' "$HGUARD_SSH_SOCKET_OVERRIDE"; then
  fail "socket override must omit IPv6 ListenStream when /proc/net/if_inet6 is absent"
fi

: > "$HGUARD_PROC_ROOT/net/if_inet6"  # IPv6 available
rm -f "$HGUARD_SSH_SOCKET_OVERRIDE"
write_hguard_ssh_socket_override false
assert_file_contains "$HGUARD_SSH_SOCKET_OVERRIDE" "[::]:22"

pass "write_hguard_ssh_socket_override respects IPv6 availability"
