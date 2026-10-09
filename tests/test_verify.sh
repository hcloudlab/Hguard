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
mkdir -p "$HGUARD_STATE_DIR"
# shellcheck source=verify.sh
. "$TEST_ROOT/verify.sh"

id() { [ "$1" = "-u" ] && printf '0\n' || return 0; }
validate_existing_user_account() { :; }
verify_authorized_keys() { return 0; }
verify_sudo_configuration() { return 0; }
verify_effective_sshd_config() { return 0; }
verify_ssh_runtime_healthy() { return 0; }
verify_ssh_listener() { return 0; }
ufw_is_active() { return 0; }
ufw_tcp_rule_exists() { return 0; }
verify_config_permissions() { return 0; }
systemctl() { return 0; }
fail2ban-client() { return 0; }
sysctl() { [ "$2" = "net.ipv4.tcp_congestion_control" ] && printf 'bbr\n' || printf 'fq\n'; }

printf "NEW_USER='admin'\nSUDO_MODE='password'\nSSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"

output="$(main)"
assert_equal 'PASS: all acceptance checks passed.' "$output" "verify reports PASS when every check passes"
[ ! -e "$HGUARD_INSTALLED_MARKER" ] || fail "verify must never write the installed marker"

# The actual bug: run_acceptance_checks' own warn() reason for the
# failing check must reach the user in non-quiet mode, not just the
# final FAIL count - previously it was piped through `| tail -n1` and
# silently discarded regardless of --quiet.
ufw_is_active() { return 1; }
output="$(main 2>&1 || true)"
case "$output" in
  *"Acceptance: UFW is inactive."*) ;;
  *) fail "non-quiet FAIL output does not show the specific failing check's reason (got: ${output})" ;;
esac
case "$output" in
  *"FAIL: 1 acceptance check(s) failed."*) ;;
  *) fail "non-quiet FAIL output is missing the summary line (got: ${output})" ;;
esac

quiet_output="$(main --quiet 2>&1 || true)"
QUIET="false"
assert_equal 'FAIL: 1 acceptance check(s) failed.' "$quiet_output" "--quiet suppresses the per-check warn line, keeping only the result"

if (main) 2>/dev/null; then
  fail "verify must exit non-zero when a check fails"
fi
QUIET="false"
ufw_is_active() { return 0; }

# SUDO_MODE specifically missing (not just absent entirely) must be
# caught with a clear error, not let verify_sudo_configuration silently
# fail on an empty SUDO_MODE and get reported as an ordinary acceptance
# failure indistinguishable from a real sudo problem.
: > "$HGUARD_CONFIG_FILE"
printf "NEW_USER='admin'\nSSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"
if (main) 2>/dev/null; then
  fail "verify must refuse to run with no sudo mode configured"
fi

unset NEW_USER
: > "$HGUARD_CONFIG_FILE"
if (main) 2>/dev/null; then
  fail "verify must refuse to run with no managed administrator configured"
fi

pass "hguard verify reuses run_acceptance_checks read-only, supports --quiet, and fails closed"
