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

### Second scenario: root pubkey is fine, but a foreign cloud-init NOPASSWD
### sudoers entry conflicts with the requested password sudo mode. This must
### also be caught, and block upgrade_system, before any apt upgrade runs.
ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/root_key" </dev/null
cp "$temporary_root/root_key.pub" "$ROOT_AUTHORIZED_KEYS"
export SUDOERS_DIR="$temporary_root/sudoers.d"
mkdir -p "$SUDOERS_DIR"
printf 'admin ALL=(ALL) NOPASSWD: ALL\n' > "$SUDOERS_DIR/90-cloud-init-users"
managed_file_is_owned() { return 1; }

rm -f "$upgrade_marker"
resolve_sudo_mode() { SUDO_MODE="password"; }

if (main) 2>/dev/null; then
  fail "main should error on a foreign NOPASSWD sudoers conflict in password mode"
fi
[ ! -e "$upgrade_marker" ] || fail "upgrade_system must not run when the sudo-mode preflight fails"

pass "check_sudo_mode_compatibility runs before upgrade_system and blocks it on a cloud-init NOPASSWD conflict"
