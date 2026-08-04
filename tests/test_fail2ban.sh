#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

export VPSGUARD_TEST_MODE=1
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

status_attempts=0
# Called indirectly by wait_for_fail2ban_sshd_jail.
# shellcheck disable=SC2329
fail2ban-client() {
  [ "$*" = "status sshd" ] || return 1
  status_attempts=$((status_attempts + 1))
  [ "$status_attempts" -ge 3 ]
}
sleep() { :; }

assert_success wait_for_fail2ban_sshd_jail 5
assert_equal 3 "$status_attempts" "fail2ban readiness retry count"

status_attempts=0
# Called indirectly by wait_for_fail2ban_sshd_jail.
# shellcheck disable=SC2329
fail2ban-client() {
  status_attempts=$((status_attempts + 1))
  return 1
}
assert_failure wait_for_fail2ban_sshd_jail 3
assert_equal 3 "$status_attempts" "bounded fail2ban readiness attempts"

pass "bounded fail2ban sshd jail readiness retries"
