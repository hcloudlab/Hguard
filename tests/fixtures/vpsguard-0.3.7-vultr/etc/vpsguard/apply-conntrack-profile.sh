#!/usr/bin/env bash
# Managed by VPSGuard 0.3.7; optional conntrack runtime floor.
set -euo pipefail

PROC_SYS_ROOT="${VPSGUARD_PROC_SYS_ROOT:-/proc/sys}"
MAX_FILE="${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_max"
SYN_SENT_FILE="${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_syn_sent"
SYN_RECV_FILE="${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_syn_recv"
TIME_WAIT_FILE="${PROC_SYS_ROOT}/net/netfilter/nf_conntrack_tcp_timeout_time_wait"

read_uint() {
  local file="$1"
  [ -r "$file" ] || return 1
  awk 'NF {print; exit}' "$file" | grep -Eq '^[0-9]+$'
  awk 'NF {print; exit}' "$file"
}

write_value() {
  local file="$1"
  local value="$2"
  [ -e "$file" ] || return 0
  printf '%s\n' "$value" > "$file" 2>/dev/null || true
}

if current_max="$(read_uint "$MAX_FILE" 2>/dev/null)" && [ "$current_max" -lt 65536 ]; then
  write_value "$MAX_FILE" 65536
fi
write_value "$SYN_SENT_FILE" 30
write_value "$SYN_RECV_FILE" 20
write_value "$TIME_WAIT_FILE" 30
