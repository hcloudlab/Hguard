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
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

sample_22='22/tcp                     ALLOW IN    Anywhere'
sample_2222='2222/tcp                   ALLOW IN    Anywhere'
sample_v6='22/tcp (v6)                ALLOW IN    Anywhere (v6)'

printf '%s\n' "$sample_22" | ufw_rule_exists_from_text 22 || fail "22/tcp was not recognized"
if printf '%s\n' "$sample_2222" | ufw_rule_exists_from_text 22; then
  fail "22/tcp matched 2222/tcp"
fi
if printf '%s\n' "$sample_22" | ufw_rule_exists_from_text 2222; then
  fail "2222/tcp matched 22/tcp"
fi
printf '%s\n' "$sample_v6" | ufw_rule_exists_from_text 22 || fail "IPv6 22/tcp rule was not recognized"
printf 'ufw allow 22/tcp\n' | ufw_added_rule_exists_from_text 22 || fail "inactive UFW rule was not recognized"

ufw_calls="$temporary_root/ufw-calls"
ufw() {
  case "$1" in
    status) printf 'Status: active\n22/tcp ALLOW IN Anywhere\n' ;;
    *) printf '%s\n' "$*" >> "$ufw_calls" ;;
  esac
}
ensure_ufw_tcp_rule 22
[ ! -e "$ufw_calls" ] || fail "existing exact rule was added again"

pass "UFW exact IPv4/IPv6 matching and duplicate prevention"
