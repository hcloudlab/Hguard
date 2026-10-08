#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HGUARD_LIB_MODE=1
# shellcheck source=install-core.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/install-core.sh"

ASSUME_YES="false"

parse_update_args() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --yes|-y) ASSUME_YES="true" ;;
      *) error "Unknown option: ${argument}" ;;
    esac
  done
}

# `apt-get -s install --only-upgrade` only promises not to *newly install*
# an unrelated package - it can still pull in a new dependency for one of
# the five, or (in principle) remove a conflicting one. Simulate first and
# surface the *entire* plan (not just the five), so the operator sees
# anything else apt intends to touch before it actually runs.
simulate_update() {
  local packages="$1"
  # shellcheck disable=SC2086
  apt-get -s -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --only-upgrade $packages
}

simulation_would_remove() {
  printf '%s\n' "$1" | grep -Eq '^Remv '
}

simulation_plan_lines() {
  printf '%s\n' "$1" | grep -E '^(Inst|Conf|Remv) '
}

main() {
  local upgradable package installed candidate packages simulation
  local verify_output verify_status

  parse_update_args "$@"
  [ "$(id -u)" -eq 0 ] || error "Please run hguard update as root."

  upgradable="$(upgradable_managed_packages)"
  if [ -z "$upgradable" ]; then
    printf 'All managed components are already at their candidate version. Nothing to update.\n'
    return 0
  fi

  apt-get update >/dev/null

  printf 'The following managed components can be upgraded:\n'
  printf '%s\n' "$upgradable" | awk '{printf "  %s: %s -> %s\n", $1, $2, $3}'

  packages="$(printf '%s\n' "$upgradable" | awk '{print $1}' | tr '\n' ' ')"
  simulation="$(simulate_update "$packages")"

  if simulation_would_remove "$simulation"; then
    printf '\napt would remove one or more packages to perform this upgrade:\n'
    simulation_plan_lines "$simulation" | sed 's/^/  /'
    error "Refusing to proceed; resolve this manually (e.g. apt-get install --only-upgrade ${packages}) and inspect what apt wants to remove."
  fi

  printf '\nFull apt plan for this update (not just the five managed packages):\n'
  simulation_plan_lines "$simulation" | sed 's/^/  /'

  if [ "$ASSUME_YES" != "true" ]; then
    local confirmation=""
    [ -t 0 ] || error "Confirmation requires an interactive terminal; rerun with --yes for non-interactive use."
    read -r -p "Proceed with this upgrade? [y/N]: " confirmation
    case "$confirmation" in
      y|Y|yes|YES) ;;
      *) printf 'Cancelled.\n'; return 0 ;;
    esac
  fi

  export NEEDRESTART_MODE=l
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --only-upgrade -y $packages

  prepare_sshd_runtime_directory

  if ! NEW_USER="$(read_env_value "$HGUARD_CONFIG_FILE" NEW_USER 2>/dev/null)" || [ -z "$NEW_USER" ]; then
    error "No managed administrator is configured; cannot verify after update."
  fi
  if ! SSH_PORT="$(read_env_value "$HGUARD_CONFIG_FILE" SSH_PORT 2>/dev/null)" || [ -z "$SSH_PORT" ]; then
    error "No managed SSH port is configured; cannot verify after update."
  fi
  verify_output="$(run_acceptance_checks)"
  verify_status=0
  read -r failures _ <<< "$(printf '%s\n' "$verify_output" | tail -n1)"
  [ "$failures" -eq 0 ] || verify_status=1

  printf '\nUpgraded components:\n'
  printf '%s\n' "$upgradable" | awk '{printf "  %s: %s -> %s\n", $1, $2, $3}'

  if [ "$verify_status" -eq 0 ]; then
    printf '\nVerification: PASS\n'
  else
    printf '\nVerification: FAIL\n' >&2
    warn "Acceptance checks failed after the update. Keep the current SSH session open and investigate before disconnecting."
    return 1
  fi
}

if [ "$HGUARD_TEST_MODE" != "1" ]; then
  main "$@"
fi
