#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_MANAGED_RULES="$HGUARD_STATE_DIR/managed-rules"
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

# Real `ss -ltnupH` output captured on an AWS Ubuntu 24.04 instance. Two
# past bugs made this misreport: (1) a second `ss -lunupH` call (no Netid
# column) used to be concatenated in, which misread its peer-address "*" as
# the port and its state as the protocol; (2) loopback addresses decorated
# with a %ifname suffix (systemd-resolve's 127.0.0.53%lo) or IPv6 brackets
# ([::1]) were not recognized as loopback. The only real foreign listener
# here is systemd-network's DHCP client on the public-ish interface address.
export SS_LISTEN_ALL_OUTPUT_OVERRIDE='udp UNCONN 0      0                127.0.0.54:53    0.0.0.0:*  users:(("systemd-resolve",pid=9094,fd=16))
udp UNCONN 0      0             127.0.0.53%lo:53    0.0.0.0:*  users:(("systemd-resolve",pid=9094,fd=14))
udp UNCONN 0      0        172.31.23.127%ens5:68    0.0.0.0:*  users:(("systemd-network",pid=4210,fd=22))
udp UNCONN 0      0                 127.0.0.1:323   0.0.0.0:*  users:(("chronyd",pid=718,fd=5))
udp UNCONN 0      0                     [::1]:323      [::]:*  users:(("chronyd",pid=718,fd=6))
tcp LISTEN 0      4096          127.0.0.53%lo:53    0.0.0.0:*  users:(("systemd-resolve",pid=9094,fd=15))
tcp LISTEN 0      4096                0.0.0.0:22    0.0.0.0:*  users:(("sshd",pid=24473,fd=3),("systemd",pid=1,fd=143))
tcp LISTEN 0      4096             127.0.0.54:53    0.0.0.0:*  users:(("systemd-resolve",pid=9094,fd=17))
tcp LISTEN 0      4096                   [::]:22       [::]:*  users:(("sshd",pid=24473,fd=4),("systemd",pid=1,fd=144))'
SSH_PORT=22
result="$(survey_foreign_listening_ports)"
assert_equal "68/udp	systemd-network" "$result" "only the non-loopback DHCP client listener survives the real AWS ss output"

pass "survey_foreign_listening_ports handles real AWS ss output: %ifname loopback, no redundant udp-only call"

# A second ss -ltnupH case with both an IPv4 and an IPv6 listener on the
# same TCP port, plus a UDP listener, to confirm dedup-by-port/proto and
# IPv6 bracket handling together.
export SS_LISTEN_ALL_OUTPUT_OVERRIDE='tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
tcp LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=2,fd=4))
tcp LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=2,fd=5))
udp UNCONN 0 0 0.0.0.0:8443 0.0.0.0:* users:(("myapp",pid=4,fd=6))'
SSH_PORT=22
result="$(survey_foreign_listening_ports)"
assert_equal "443/tcp	nginx
8443/udp	myapp" "$result" "dual-stack tcp listener on the same port is deduplicated; udp listener is kept"

pass "survey_foreign_listening_ports deduplicates a dual-stack TCP port and keeps a UDP port"

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

# select_ports_from_survey: interactive selection accepts the same token
# format as ALLOW_PORTS. A bare port number must allow every protocol the
# survey found on it - previously it silently took only the first matching
# survey row, i.e. TCP whenever a port had both TCP and UDP listeners,
# because survey_foreign_listening_ports always lists TCP rows first.
survey='443/tcp	nginx
443/udp	quic-app
8443/udp	myapp'

assert_equal "443/tcp
443/udp" "$(select_ports_from_survey "$survey" 443)" "a bare port allows every detected protocol on it"

assert_equal "443/tcp" "$(select_ports_from_survey "$survey" 443/tcp)" "port/tcp allows only tcp"
assert_equal "443/udp" "$(select_ports_from_survey "$survey" 443/udp)" "port/udp allows only udp"

if (select_ports_from_survey "$survey" 443/sctp) 2>/dev/null; then
  fail "select_ports_from_survey should reject a protocol other than tcp/udp"
fi
if (select_ports_from_survey "$survey" 9999) 2>/dev/null; then
  fail "select_ports_from_survey should reject a port not in the survey"
fi

pass "select_ports_from_survey accepts ALLOW_PORTS-style tokens; bare ports allow all detected protocols"
