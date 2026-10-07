#!/usr/bin/env bash
set -euo pipefail

# VPSGuard v0.3.6
# Default entrypoint. A normal install applies the validated conntrack profile
# before continuing with the existing SSH/UFW/fail2ban/BBR hardening flow.

# shellcheck disable=SC2034
VPSGUARD_VERSION="0.3.6"
if SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; then
  :
else
  SCRIPT_DIR=""
fi
LOCAL_CORE="${SCRIPT_DIR}/install-core.sh"
CORE_URL="https://raw.githubusercontent.com/hcloudlab/vpsguard/v${VPSGUARD_VERSION}/install-core.sh"
TEMP_CORE=""

cleanup() {
  [ -z "$TEMP_CORE" ] || rm -f "$TEMP_CORE"
}
trap cleanup EXIT

resolve_core() {
  if [ -f "$LOCAL_CORE" ]; then
    printf '%s\n' "$LOCAL_CORE"
    return 0
  fi

  TEMP_CORE="$(mktemp /tmp/vpsguard-install-core.XXXXXX)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 \
      "$CORE_URL" -o "$TEMP_CORE"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TEMP_CORE" "$CORE_URL"
  else
    printf '[ERROR] curl or wget is required to load the VPSGuard core installer.\n' >&2
    exit 1
  fi
  printf '%s\n' "$TEMP_CORE"
}

CORE_SCRIPT="$(resolve_core)"

# Isolated repository tests source install.sh to access the implementation
# functions. Preserve that contract without executing the wrapper workflow.
if [ "${VPSGUARD_TEST_MODE:-0}" = "1" ]; then
  # shellcheck source=install-core.sh
  # shellcheck disable=SC1090
  . "$CORE_SCRIPT"
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

# Preserve the existing standalone/help interfaces exactly. Unknown argument
# combinations, and the default no-args install, are delegated to the core so
# its validation remains the single source of truth. The core applies the
# conntrack profile itself, after BBR, inside its own default flow.
exec bash "$CORE_SCRIPT" "$@"
