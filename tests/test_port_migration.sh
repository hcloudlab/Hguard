#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_CONFIG_FILE="$VPSGUARD_STATE_DIR/config.env"
export VPSGUARD_MANAGED_RULES="$VPSGUARD_STATE_DIR/managed-rules"
export VPSGUARD_INSTALLED_MARKER="$VPSGUARD_STATE_DIR/.installed"
export VPSGUARD_PENDING_PORT_MARKER="$VPSGUARD_STATE_DIR/.pending-port-finalization"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

mkdir -p "$VPSGUARD_STATE_DIR"
SSH_PORT=2222
ORIGINAL_SSH_PORT=22

resolve_port_migration_requirement 2222
assert_equal true "$PORT_MIGRATION_REQUIRED" "first install requires safe port migration"

atomic_write "$VPSGUARD_INSTALLED_MARKER" 600 $'success\n'
resolve_port_migration_requirement 2222
assert_equal false "$PORT_MIGRATION_REQUIRED" "finalized rerun must not recreate migration"

NEW_USER='repeatadmin'
SUDO_MODE='password'
INSTALL_STATUS='failed'
write_config_env
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 2222'
SSH_PORT=""
ORIGINAL_SSH_PORT=""
resolve_ssh_ports
assert_equal 2222 "$SSH_PORT" "rerun preserves configured target port"
assert_equal 22 "$ORIGINAL_SSH_PORT" "rerun preserves historical original port"
assert_equal false "$PORT_MIGRATION_REQUIRED" "failed rerun status does not erase prior finalization"

atomic_write "$VPSGUARD_PENDING_PORT_MARKER" 600 $'target=2222\nold=22\n'
resolve_port_migration_requirement 2222
assert_equal true "$PORT_MIGRATION_REQUIRED" "pending install still requires finalization"
rm -f "$VPSGUARD_PENDING_PORT_MARKER"

SSH_PORT=3333
resolve_port_migration_requirement 2222
assert_equal true "$PORT_MIGRATION_REQUIRED" "changed target port requires safe migration"
SSH_PORT=2222

requested_ufw_ports=""
ufw_is_active() { return 0; }
ensure_ufw_tcp_rule() { requested_ufw_ports="${requested_ufw_ports}${1},"; }

PORT_MIGRATION_REQUIRED=false
configure_ufw_before_ssh
assert_equal '2222,' "$requested_ufw_ports" "finalized rerun must not reopen old UFW port"

requested_ufw_ports=""
PORT_MIGRATION_REQUIRED=true
configure_ufw_before_ssh
assert_equal '2222,22,' "$requested_ufw_ports" "active migration must preserve both UFW ports"

runtime_policy_calls=""
write_vpsguard_ssh_runtime_policy() { runtime_policy_calls="${runtime_policy_calls}${1},"; }
verify_effective_sshd_config() { return 0; }
apply_ssh_runtime() { return 0; }
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2329
verify_ssh_listener() { return 0; }
ufw_tcp_rule_exists() { return 0; }

PORT_MIGRATION_REQUIRED=false
configure_ssh_safely
assert_equal 'false,' "$runtime_policy_calls" "finalized rerun writes target-only SSH policy"
[ ! -e "$VPSGUARD_PENDING_PORT_MARKER" ] || fail "finalized rerun recreated pending migration marker"

pass "finalized reruns do not restore the old SSH port"

# Simulate the old port still being listened on after finalization
# (e.g. a second `Port` directive elsewhere in sshd_config).
verify_ssh_listener() {
  case "$1" in
    "$SSH_PORT") return 0 ;;
    "$ORIGINAL_SSH_PORT") return 0 ;;  # still up — this is the bug condition
  esac
  return 1
}
# The real code only prompts when interactive_terminal_available (a thin
# wrapper around `[ -t 0 ]`) is true - stub it so this test is deterministic
# regardless of whether this script happens to be run from a real terminal.
# The real call is `read -r -p "prompt" answer`; the variable name to set is
# always the last argument, available via bash's ${!#} indirect expansion.
interactive_terminal_available() { return 0; }
# Read via eval indirection below, not a direct reference.
# shellcheck disable=SC2034
answer_override="YES"
read() { eval "${!#}=\$answer_override"; }

PORT_MIGRATION_REQUIRED=true
SSH_PORT=2222
ORIGINAL_SSH_PORT=22
configure_ssh_safely
assert_equal "success-with-warnings" "$INSTALL_STATUS" "finalization warns when the old port is still listening"

pass "configure_ssh_safely downgrades to success-with-warnings if the old port stays open"
