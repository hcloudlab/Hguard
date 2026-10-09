#!/usr/bin/env bash
set -euo pipefail

# Invoked by DPkg::Post-Invoke after every apt run (see
# install_apt_hook() in install-core.sh for the managed apt.conf.d file).
# Must never fail apt: every exit path below is 0, even on error - a
# trap guarantees it regardless of where execution stops. Skipped under
# HGUARD_TEST_MODE, which sources this file to unit-test its functions
# rather than running it as apt would - the trap would otherwise force
# the sourcing test script itself to exit 0, silently hiding failures.
if [ "${HGUARD_TEST_MODE:-0}" != "1" ]; then
  trap 'exit 0' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HGUARD_LIB_MODE=1
# shellcheck source=install-core.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/install-core.sh"

main() {
  local current_versions previous_versions verify_status

  [ "$(id -u)" -eq 0 ] || return 0
  [ -f "$HGUARD_CONFIG_FILE" ] || return 0

  current_versions="$(managed_package_version_snapshot)"
  previous_versions=""
  if [ -f "$HGUARD_APT_HOOK_VERSIONS_FILE" ]; then
    previous_versions="$(cat "$HGUARD_APT_HOOK_VERSIONS_FILE" 2>/dev/null || printf '')"
  fi
  [ "$current_versions" != "$previous_versions" ] || return 0

  ensure_directory "$HGUARD_STATE_DIR" 700
  printf '%s' "$current_versions" > "$HGUARD_APT_HOOK_VERSIONS_FILE" 2>/dev/null || true

  if ! NEW_USER="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)" || [ -z "$NEW_USER" ]; then
    return 0
  fi
  if ! SSH_PORT="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)" || [ -z "$SSH_PORT" ]; then
    return 0
  fi
  if ! SUDO_MODE="$(read_env_value "$HGUARD_CONFIG_FILE" SUDO_MODE 2>/dev/null)" || ! validate_sudo_mode "$SUDO_MODE"; then
    return 0
  fi

  warn() { :; }
  run_acceptance_checks
  verify_status="FAIL"
  [ "$ACCEPTANCE_FAILURES" -eq 0 ] && verify_status="PASS"

  atomic_write "$HGUARD_APT_HOOK_STATE_FILE" 600 "TIMESTAMP='$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
RESULT='${verify_status}'
" 2>/dev/null || true
  log_plain INFO "apt hook: managed component versions changed, verify result ${verify_status}."
  return 0
}

if [ "$HGUARD_TEST_MODE" != "1" ]; then
  main
fi
