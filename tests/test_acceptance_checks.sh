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
export HGUARD_INSTALLED_MARKER="$HGUARD_STATE_DIR/.installed"
mkdir -p "$HGUARD_STATE_DIR"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

# run_acceptance_checks must be read-only - this is the whole point of
# splitting it out of run_final_acceptance: `hguard verify` (a read-only
# recheck, run frequently by the apt hook) reuses exactly this function and
# must never write config/state as a side effect of merely checking it.
NEW_USER="admin"
SSH_PORT=22
INSTALL_STATUS="success"
id() { return 0; }
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

# Counts come back via ACCEPTANCE_FAILURES/ACCEPTANCE_WARNINGS globals,
# not a stdout line - called as a bare statement, not `$(...)`, so any
# warn() output (none expected here) would reach the terminal directly
# instead of being captured and discarded.
run_acceptance_checks
assert_equal "0 0" "${ACCEPTANCE_FAILURES} ${ACCEPTANCE_WARNINGS}" "all-pass checks report zero failures and zero warnings"
[ ! -e "$HGUARD_CONFIG_FILE" ] || fail "run_acceptance_checks must not write config.env"
[ ! -e "$HGUARD_INSTALLED_MARKER" ] || fail "run_acceptance_checks must not write the installed marker"

# run_final_acceptance still does the install-time side effects: it wraps
# run_acceptance_checks and persists on success, exactly as before the split.
assert_success run_final_acceptance
[ -e "$HGUARD_CONFIG_FILE" ] || fail "run_final_acceptance should still write config.env on success"
[ -e "$HGUARD_INSTALLED_MARKER" ] || fail "run_final_acceptance should still write the installed marker on success"
assert_file_contains "$HGUARD_INSTALLED_MARKER" "success"

# A failing check must still be reflected in the failure count and make
# run_final_acceptance fail, without it or run_acceptance_checks itself
# needing to know anything about what the count means.
ufw_is_active() { return 1; }
run_acceptance_checks
assert_equal "1 0" "${ACCEPTANCE_FAILURES} ${ACCEPTANCE_WARNINGS}" "a single failing check reports one failure"
assert_failure run_final_acceptance

pass "run_acceptance_checks is read-only; run_final_acceptance keeps the install-time persistence"
