#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_MANAGED_RULES="$VPSGUARD_STATE_DIR/managed-rules"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

export SS_LISTEN_ALL_OUTPUT_OVERRIDE='tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=1,fd=3))
tcp   LISTEN 0      511          0.0.0.0:443        0.0.0.0:*     users:(("nginx",pid=2,fd=4))
tcp   LISTEN 0      128        127.0.0.1:3306        0.0.0.0:*     users:(("mysqld",pid=3,fd=5))
udp   UNCONN 0      0            0.0.0.0:8443        0.0.0.0:*     users:(("myapp",pid=4,fd=6))'

SSH_PORT=22
result="$(survey_foreign_listening_ports)"
assert_equal "443/tcp	nginx
8443/udp	myapp" "$result" "survey excludes ssh port and loopback-only listeners"

pass "survey_foreign_listening_ports excludes SSH and loopback listeners"

assert_equal "443/tcp
8443/udp" "$(parse_allow_ports '443/tcp,8443/udp')" "parse_allow_ports normalizes a valid list"

assert_failure parse_allow_ports '443/tcp,abc'
assert_failure parse_allow_ports '70000/tcp'
assert_failure parse_allow_ports '443/sctp'

pass "parse_allow_ports validates port/proto tokens"

export SS_LISTEN_ALL_OUTPUT_OVERRIDE='tcp   LISTEN 0 128  0.0.0.0:22   0.0.0.0:*  users:(("sshd",pid=1,fd=3))
tcp   LISTEN 0 511  0.0.0.0:443  0.0.0.0:*  users:(("nginx",pid=2,fd=4))'
SSH_PORT=22
PORT_MIGRATION_REQUIRED="false"
ufw_calls=""
ufw_state_file="$temporary_root/ufw-active"
printf 'false\n' > "$ufw_state_file"
ufw() {
  ufw_calls="$ufw_calls $*"
  if [ "$1" = "status" ]; then
    if [ "$(cat "$ufw_state_file")" = "true" ]; then printf 'Status: active\n'; else printf 'Status: inactive\n'; fi
  elif [ "$1" = "--force" ] && [ "$2" = "enable" ]; then
    printf 'true\n' > "$ufw_state_file"
  fi
}
ensure_ufw_tcp_rule() { :; }
record_managed_rule() { printf 'recorded:%s\n' "$1" >>"$temporary_root/recorded"; }

# No ALLOW_PORTS, no --ssh-only, non-interactive (stdin not a tty under test runner): must error.
# configure_ufw_before_ssh calls error(), which exits the process, so run it in a
# subshell to check its exit status without killing this whole test script.
REQUESTED_ALLOW_PORTS=""
ALLOW_SSH_ONLY="false"
if (configure_ufw_before_ssh) 2>/dev/null; then
  fail "configure_ufw_before_ssh should error without ALLOW_PORTS/--ssh-only when foreign ports are listening"
fi

# --ssh-only: proceeds, nothing extra recorded.
printf 'false\n' > "$ufw_state_file"
: > "$temporary_root/recorded"
ALLOW_SSH_ONLY="true"
configure_ufw_before_ssh
assert_equal "" "$(cat "$temporary_root/recorded" 2>/dev/null)" "--ssh-only records no extra ports"

# ALLOW_PORTS=443/tcp: records exactly that port.
printf 'false\n' > "$ufw_state_file"
: > "$temporary_root/recorded"
ALLOW_SSH_ONLY="false"
REQUESTED_ALLOW_PORTS="443/tcp"
configure_ufw_before_ssh
assert_equal "recorded:443/tcp" "$(cat "$temporary_root/recorded")" "ALLOW_PORTS=443/tcp records that port"

pass "configure_ufw_before_ssh gates correctly in non-interactive mode"
