#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HGUARD_LIB_MODE=1
# shellcheck source=install-core.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/install-core.sh"

QUIET="false"

parse_verify_args() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --quiet) QUIET="true" ;;
      *) error "Unknown option: ${argument}" ;;
    esac
  done
}

main() {
  parse_verify_args "$@"
  [ "$(id -u)" -eq 0 ] || error "Please run hguard verify as root."

  if ! NEW_USER="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)" || [ -z "$NEW_USER" ]; then
    error "No managed administrator is configured; run the installer first."
  fi
  if ! SSH_PORT="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)" || [ -z "$SSH_PORT" ]; then
    error "No managed SSH port is configured; run the installer first."
  fi
  if ! SUDO_MODE="$(read_env_value "$HGUARD_CONFIG_FILE" SUDO_MODE 2>/dev/null)" || ! validate_sudo_mode "$SUDO_MODE"; then
    error "No valid sudo mode is configured; run the installer first."
  fi
  if [ "$QUIET" = "true" ]; then
    # run_acceptance_checks' own warn() calls would otherwise print one
    # line per failing check; --quiet (the apt hook's mode, run after
    # every relevant apt invocation) keeps this to a single result line.
    warn() { :; }
  fi

  # A bare statement, not `$(...)`: run_acceptance_checks' warn() output
  # must reach the terminal directly in non-quiet mode, not get piped
  # through and discarded - that was the whole bug. The failure/warning
  # counts come back via its ACCEPTANCE_FAILURES/ACCEPTANCE_WARNINGS
  # globals instead of a stdout line.
  run_acceptance_checks

  if [ "$ACCEPTANCE_FAILURES" -eq 0 ] && [ "$ACCEPTANCE_WARNINGS" -eq 0 ]; then
    printf 'PASS: all acceptance checks passed.\n'
    return 0
  elif [ "$ACCEPTANCE_FAILURES" -eq 0 ]; then
    printf 'PASS (with warnings): acceptance checks passed with %s warning(s).\n' "$ACCEPTANCE_WARNINGS"
    return 0
  else
    printf 'FAIL: %s acceptance check(s) failed.\n' "$ACCEPTANCE_FAILURES"
    return 1
  fi
}

if [ "$HGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
