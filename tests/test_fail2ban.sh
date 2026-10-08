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
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2329
systemctl() {
  case "$*" in
    'enable fail2ban.service') return 0 ;;
    'restart fail2ban.service') restart_count=$((restart_count + 1)); sshd_jail_available="true"; return 0 ;;
    'is-active --quiet fail2ban.service') [ "$service_active" = "true" ] ;;
    *) return 1 ;;
  esac
}
# shellcheck disable=SC2329
fail2ban-client() {
  [ "$1" = "-t" ] && return 0
  [ "$*" = "status sshd" ] && [ "$sshd_jail_available" = "true" ]
}
configure_fail2ban
assert_equal 1 "$restart_count" "unchanged jail content but unavailable sshd jail still restarts"

pass "configure_fail2ban restarts when runtime state is wrong, even if the jail file is unchanged"

# The installer's own connection IP must be exempted from fail2ban, or a
# client that retries several local SSH keys before the right one can ban
# its own installer for an hour - reproduced on a real Vultr instance.
assert_success looks_like_ip_address 203.0.113.5
assert_success looks_like_ip_address 2001:db8::1
assert_failure looks_like_ip_address "not an ip"
assert_failure looks_like_ip_address ""

SSH_CONNECTION="203.0.113.5 54321 198.51.100.1 22"
assert_equal 203.0.113.5 "$(current_connection_ip)" "SSH_CONNECTION's first field is the client address"

# sudo -i can clear SSH_CONNECTION; who -m's "(address)" suffix is the
# fallback.
SSH_CONNECTION=""
# Called indirectly by current_connection_ip.
# shellcheck disable=SC2329
who() { [ "$1" = "-m" ] && printf 'admin    pts/0        2026-10-08 10:00 (198.51.100.42)\n'; }
assert_equal 198.51.100.42 "$(current_connection_ip)" "who -m's address is used when SSH_CONNECTION is empty"

# Neither source yields an address: current_connection_ip must fail, and
# configure_fail2ban must neither add a bogus ignoreip entry nor silently
# say nothing about it.
SSH_CONNECTION=""
who() { [ "$1" = "-m" ] && printf 'admin    pts/0        2026-10-08 10:00\n'; }
assert_failure current_connection_ip

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
FAIL2BAN_JAIL="$temporary_root/vpsguard-sshd.local"
SSH_PORT=22
ORIGINAL_SSH_PORT=22
VPSGUARD_PENDING_PORT_MARKER="$temporary_root/.pending-port-finalization"
rm -f "$VPSGUARD_PENDING_PORT_MARKER"
systemctl() {
  case "$*" in
    'enable fail2ban.service') return 0 ;;
    'restart fail2ban.service') return 0 ;;
    'is-active --quiet fail2ban.service') return 0 ;;
    *) return 1 ;;
  esac
}
fail2ban-client() {
  [ "$1" = "-t" ] && return 0
  [ "$*" = "status sshd" ] && return 0
  return 1
}

fail2ban_no_ip_output_file="$temporary_root/configure-fail2ban-output.log"
configure_fail2ban > "$fail2ban_no_ip_output_file" 2>&1
assert_file_contains "$FAIL2BAN_JAIL" 'ignoreip = 127.0.0.1/8 ::1'
if grep -q '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}$' "$FAIL2BAN_JAIL"; then
  fail "no extra address should be appended to ignoreip when none could be determined"
fi
assert_file_contains "$fail2ban_no_ip_output_file" '无法确定当前连接的来源 IP'
assert_equal "" "$INSTALLER_IP" "INSTALLER_IP stays empty when no connection address could be determined"

SSH_CONNECTION="203.0.113.5 54321 198.51.100.1 22"
rm -f "$FAIL2BAN_JAIL"
configure_fail2ban
assert_file_contains "$FAIL2BAN_JAIL" 'ignoreip = 127.0.0.1/8 ::1 203.0.113.5'
assert_equal 203.0.113.5 "$INSTALLER_IP" "configure_fail2ban records the installer's IP for the final summary"

pass "configure_fail2ban exempts the current connection's IP, or warns if none could be determined"
