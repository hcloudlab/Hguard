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
export ROOT_AUTHORIZED_KEYS="$temporary_root/root-authorized_keys"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

: > "$ROOT_AUTHORIZED_KEYS"  # empty: check_root_ssh_key must fail

# main() calls the real error(), which exits the process. Run it in a real
# subshell so that exit only kills the subshell, not this whole test script.
# A shell *variable* set by a stub inside that subshell would NOT be visible
# out here (subshells don't share variable state back to the parent) - so
# the stub records to a file on disk instead, which does survive.
upgrade_marker="$temporary_root/upgrade-called"
rm -f "$upgrade_marker"
upgrade_system() { touch "$upgrade_marker"; }
require_root() { :; }
check_ubuntu_lts() { :; }
parse_args() { :; }
resolve_managed_user() { NEW_USER="admin"; }
resolve_sudo_mode() { SUDO_MODE="passwordless"; }
resolve_ssh_ports() { SSH_PORT=22; ORIGINAL_SSH_PORT=22; }
prepare_sshd_runtime_directory() { :; }
write_pending_config_env() { :; }
record_preinstall_state() { :; }

if (main) 2>/dev/null; then
  fail "main should error when check_root_ssh_key fails"
fi
[ ! -e "$upgrade_marker" ] || fail "upgrade_system must not run when the root pubkey preflight fails"

pass "check_root_ssh_key runs before upgrade_system and blocks it on failure"
