#!/usr/bin/env bash
set -euo pipefail

# VPSGuard v0.3.6
# Default entrypoint. A normal install applies the validated conntrack profile
# before continuing with the existing SSH/UFW/fail2ban/BBR hardening flow.

VPSGUARD_VERSION="0.3.6"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
LOCAL_CORE="${SCRIPT_DIR}/install-core.sh"
CORE_URL="https://raw.githubusercontent.com/hcloudlab/vpsguard/7bad2718022b61139e1344c55a2e619608c530ac/install.sh"
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

  command -v curl >/dev/null 2>&1 || {
    printf '[ERROR] curl is required to load the VPSGuard core installer.\n' >&2
    exit 1
  }
  TEMP_CORE="$(mktemp /tmp/vpsguard-install-core.XXXXXX)"
  curl -fsSL --proto '=https' --tlsv1.2 \
    "$CORE_URL" -o "$TEMP_CORE"
  printf '%s\n' "$TEMP_CORE"
}

CORE_SCRIPT="$(resolve_core)"

# Isolated repository tests source install.sh to access the implementation
# functions. Preserve that contract without executing the wrapper workflow.
if [ "${VPSGUARD_TEST_MODE:-0}" = "1" ]; then
  # shellcheck disable=SC1090
  . "$CORE_SCRIPT"
  return 0 2>/dev/null || exit 0
fi

# Preserve the existing standalone/help interfaces exactly. Unknown argument
# combinations are delegated to the core so its validation remains the single
# source of truth.
if [ "$#" -gt 0 ]; then
  exec bash "$CORE_SCRIPT" "$@"
fi

# Normal VPSGuard installation now includes the conntrack capacity fix by
# default. The core keeps the safety properties already validated in v0.3.6:
# user-owned conntrack configuration is preserved, existing higher max/hashsize
# values are never lowered, and no reboot/module unload is forced.
bash "$CORE_SCRIPT" --optimize-conntrack
exec bash "$CORE_SCRIPT"
