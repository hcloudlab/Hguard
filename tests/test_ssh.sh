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
export SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config"
export VPSGUARD_SSHD_CONFIG="$temporary_root/etc/ssh/sshd_config.d/00-vpsguard.conf"
export VPSGUARD_SSH_SOCKET_OVERRIDE="$temporary_root/etc/systemd/system/ssh.socket.d/00-vpsguard.conf"
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

listener='tcp LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
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

mkdir -p "$(dirname "$SSHD_CONFIG")"
printf 'PermitRootLogin prohibit-password\nInclude /etc/ssh/sshd_config.d/*.conf\n' > "$SSHD_CONFIG"
ensure_vpsguard_sshd_include_first
assert_equal '# BEGIN VPSGuard managed include' "$(sed -n '1p' "$SSHD_CONFIG")" "VPSGuard include must precede vendor policy"
assert_equal "Include ${VPSGUARD_SSHD_CONFIG}" "$(sed -n '2p' "$SSHD_CONFIG")" "VPSGuard exact include path"
assert_equal 1 "$(grep -Fc '# BEGIN VPSGuard managed include' "$SSHD_CONFIG")" "managed include uniqueness"
ensure_vpsguard_sshd_include_first
assert_equal 1 "$(grep -Fc '# BEGIN VPSGuard managed include' "$SSHD_CONFIG")" "managed include rerun uniqueness"

write_vpsguard_ssh_socket_override true
assert_file_contains "$VPSGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream='
assert_file_contains "$VPSGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream=0.0.0.0:2222'
assert_file_contains "$VPSGUARD_SSH_SOCKET_OVERRIDE" 'ListenStream=0.0.0.0:22'
write_vpsguard_ssh_socket_override false
if grep -Fxq 'ListenStream=0.0.0.0:22' "$VPSGUARD_SSH_SOCKET_OVERRIDE"; then
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
detect_ssh_runtime_mode
assert_equal socket "$SSH_RUNTIME_MODE" "socket runtime detection"
mock_socket_present=false
detect_ssh_runtime_mode
assert_equal service "$SSH_RUNTIME_MODE" "service runtime detection without ssh.socket"

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
# shellcheck disable=SC2329
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

export VPSGUARD_PROC_ROOT="$temporary_root/proc"
mkdir -p "$VPSGUARD_PROC_ROOT/net"
rm -f "$VPSGUARD_PROC_ROOT/net/if_inet6"  # IPv6 unavailable
SSH_PORT=22
VPSGUARD_SSH_SOCKET_OVERRIDE="$temporary_root/etc/systemd/system/ssh.socket.d/01-vpsguard.conf"
write_vpsguard_ssh_socket_override false
assert_file_contains "$VPSGUARD_SSH_SOCKET_OVERRIDE" "0.0.0.0:22"
if grep -q '::' "$VPSGUARD_SSH_SOCKET_OVERRIDE"; then
  fail "socket override must omit IPv6 ListenStream when /proc/net/if_inet6 is absent"
fi

: > "$VPSGUARD_PROC_ROOT/net/if_inet6"  # IPv6 available
rm -f "$VPSGUARD_SSH_SOCKET_OVERRIDE"
write_vpsguard_ssh_socket_override false
assert_file_contains "$VPSGUARD_SSH_SOCKET_OVERRIDE" "[::]:22"

pass "write_vpsguard_ssh_socket_override respects IPv6 availability"
