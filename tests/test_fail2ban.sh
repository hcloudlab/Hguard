#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

export VPSGUARD_TEST_MODE=1
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

apt_calls=()
apt() {
  apt_calls+=("$*")
}

upgrade_system
assert_equal 3 "${#apt_calls[@]}" "dependency installation command count"
if ! printf '%s\n' "${apt_calls[2]}" | tr ' ' '\n' | grep -Fxq python3-systemd; then
  fail "fail2ban systemd backend dependency is not explicitly installed"
fi

python_systemd_available=true
python3() {
  [ "$python_systemd_available" = true ]
}

assert_success fail2ban_systemd_backend_available
python_systemd_available=false
assert_failure fail2ban_systemd_backend_available

status_attempts=0
# Called indirectly by wait_for_fail2ban_sshd_jail.
# shellcheck disable=SC2317,SC2329
fail2ban-client() {
  [ "$*" = "status sshd" ] || return 1
  status_attempts=$((status_attempts + 1))
  [ "$status_attempts" -ge 3 ]
}
sleep() { :; }

FAIL2BAN_READY_ATTEMPTS=5
assert_success wait_for_fail2ban_sshd_jail
assert_equal 3 "$status_attempts" "fail2ban readiness retry count"

status_attempts=0
# Called indirectly by wait_for_fail2ban_sshd_jail.
# shellcheck disable=SC2317,SC2329
fail2ban-client() {
  status_attempts=$((status_attempts + 1))
  return 1
}
FAIL2BAN_READY_ATTEMPTS=3
assert_failure wait_for_fail2ban_sshd_jail
assert_equal 3 "$status_attempts" "bounded fail2ban readiness attempts"

pass "explicit systemd backend dependency and bounded fail2ban readiness retries"
