#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

export VPSGUARD_TEST_MODE=1
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

apt_calls=()
apt-get() {
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

# configure_fail2ban must only restart fail2ban when its jail config actually
# changed - real atomic_write change-detection drives this, not a stub.
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
FAIL2BAN_JAIL="$temporary_root/vpsguard-sshd.local"
SSH_PORT=2222
ORIGINAL_SSH_PORT=2222
VPSGUARD_PENDING_PORT_MARKER="$temporary_root/.pending-port-finalization"
rm -f "$VPSGUARD_PENDING_PORT_MARKER"
restart_count=0
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2329
systemctl() {
  case "$*" in
    'enable fail2ban.service') return 0 ;;
    'restart fail2ban.service') restart_count=$((restart_count + 1)); return 0 ;;
    'is-active --quiet fail2ban.service') return 0 ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329
fail2ban-client() {
  [ "$1" = "-t" ] && return 0
  [ "$*" = "status sshd" ] && return 0
  return 1
}

configure_fail2ban
assert_equal 1 "$restart_count" "first run with new jail content restarts fail2ban"

configure_fail2ban
assert_equal 1 "$restart_count" "rerun with unchanged jail content does not restart fail2ban"

pass "configure_fail2ban skips the restart when the jail content is unchanged"

# File unchanged, but the service has stopped (e.g. crashed or was manually
# stopped) -> must still restart even though the jail content didn't change.
restart_count=0
service_active="false"
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2329
systemctl() {
  case "$*" in
    'enable fail2ban.service') return 0 ;;
    'restart fail2ban.service') restart_count=$((restart_count + 1)); service_active="true"; return 0 ;;
    'is-active --quiet fail2ban.service') [ "$service_active" = "true" ] ;;
    *) return 1 ;;
  esac
}
configure_fail2ban
assert_equal 1 "$restart_count" "unchanged jail content but inactive fail2ban.service still restarts"

# File unchanged and the service reports active, but the sshd jail itself is
# unavailable -> must still restart.
restart_count=0
service_active="true"
sshd_jail_available="false"
systemctl() {
  case "$*" in
    'enable fail2ban.service') return 0 ;;
    'restart fail2ban.service') restart_count=$((restart_count + 1)); sshd_jail_available="true"; return 0 ;;
    'is-active --quiet fail2ban.service') [ "$service_active" = "true" ] ;;
    *) return 1 ;;
  esac
}
fail2ban-client() {
  [ "$1" = "-t" ] && return 0
  [ "$*" = "status sshd" ] && [ "$sshd_jail_available" = "true" ]
}
configure_fail2ban
assert_equal 1 "$restart_count" "unchanged jail content but unavailable sshd jail still restarts"

pass "configure_fail2ban restarts when runtime state is wrong, even if the jail file is unchanged"
