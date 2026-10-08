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
  local result failures warnings

  parse_verify_args "$@"
  [ "$(id -u)" -eq 0 ] || error "Please run hguard verify as root."

  if ! NEW_USER="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)" || [ -z "$NEW_USER" ]; then
    error "No managed administrator is configured; run the installer first."
  fi
  if ! SSH_PORT="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)" || [ -z "$SSH_PORT" ]; then
    error "No managed SSH port is configured; run the installer first."
  fi
  if [ "$QUIET" = "true" ]; then
    # run_acceptance_checks' own warn() calls would otherwise print one
    # line per failing check; --quiet (the apt hook's mode, run after
    # every relevant apt invocation) keeps this to a single result line.
    warn() { :; }
  fi

  result="$(run_acceptance_checks | tail -n1)"
  read -r failures warnings <<< "$result"

  if [ "$failures" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    printf 'PASS: all acceptance checks passed.\n'
    return 0
  elif [ "$failures" -eq 0 ]; then
    printf 'PASS (with warnings): acceptance checks passed with %s warning(s).\n' "$warnings"
    return 0
  else
    printf 'FAIL: %s acceptance check(s) failed.\n' "$failures"
    return 1
  fi
}

if [ "$HGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
