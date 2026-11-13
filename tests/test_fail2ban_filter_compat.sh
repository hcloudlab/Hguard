#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_LOG_FILE="$temporary_root/hguard.log"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

# Without an sshd-session binary the probe uses the classic identifier.
SSHD_SESSION_BINARIES="$temporary_root/missing/sshd-session"
assert_equal sshd "$(sshd_log_identifier)" "pre-9.8 OpenSSH identifier"

# OpenSSH 9.8+ (Debian 13, Ubuntu 26.04) ships sshd-session.
mkdir -p "$temporary_root/openssh"
printf '#!/bin/sh\n' > "$temporary_root/openssh/sshd-session"
chmod 755 "$temporary_root/openssh/sshd-session"
SSHD_SESSION_BINARIES="$temporary_root/missing/sshd-session $temporary_root/openssh/sshd-session"
assert_equal sshd-session "$(sshd_log_identifier)" "OpenSSH 9.8+ identifier"
pass "sshd log identifier follows the installed OpenSSH layout"

# Emulates a real filter: fail2ban 1.1.0-6+ / Debian-patched filters accept
# both identifiers, upstream 1.0.x/1.1.0 filters accept only "sshd[pid]".
probe_log="$temporary_root/probe-lines"
patched_filter="true"
fail2ban-regex() {
  printf '%s\n' "$*" >> "$probe_log"
  [ "$1" = "-o" ] && [ "$2" = "ip" ] && [ "${4:-}" = "sshd" ] || return 1
  case "$3" in
    *" sshd["*) printf '192.0.2.10\n' ;;
    *" sshd-session["*) [ "$patched_filter" = "true" ] && printf '192.0.2.10\n' ;;
  esac
  return 0
}

verify_fail2ban_sshd_filter >/dev/null 2>&1 || fail "a patched filter must pass with sshd-session"
grep -Fq 'sshd-session[4242]: Invalid user hguard-probe from 192.0.2.10 port 4242' "$probe_log" \
  || fail "the probe must use the sshd-session identifier when that binary exists"

patched_filter="false"
if verify_fail2ban_sshd_filter >/dev/null 2>&1; then
  fail "an unpatched filter must be rejected when OpenSSH logs as sshd-session"
fi

SSHD_SESSION_BINARIES="$temporary_root/missing/sshd-session"
verify_fail2ban_sshd_filter >/dev/null 2>&1 || fail "an unpatched filter is fine for pre-9.8 OpenSSH"
pass "the sshd filter probe rejects filters that would silently never ban"

# fail2ban-regex exits 0 even when nothing matches; only the printed IP counts.
fail2ban-regex() { printf 'Lines: 1 lines, 0 ignored, 0 matched, 1 missed\n'; return 0; }
if fail2ban_sshd_filter_matches sshd >/dev/null 2>&1; then
  fail "a zero-match fail2ban-regex run must not count as a match"
fi
pass "a zero-match probe is not mistaken for success"
