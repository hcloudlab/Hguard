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
