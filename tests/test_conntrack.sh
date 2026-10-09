#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_PROC_SYS_ROOT="$temporary_root/proc/sys"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_STATE_FILE="$HGUARD_STATE_DIR/state.env"
export HGUARD_MANAGED_RULES="$HGUARD_STATE_DIR/managed-rules"
export CONNTRACK_SYSCTL_FILE="$temporary_root/etc/sysctl.d/99-hguard-conntrack.conf"
export CONNTRACK_MODPROBE_FILE="$temporary_root/etc/modprobe.d/hguard-nf-conntrack.conf"
export CONNTRACK_MODULES_FILE="$temporary_root/etc/modules-load.d/hguard-conntrack.conf"
export CONNTRACK_HELPER_FILE="$temporary_root/etc/hguard/apply-conntrack-profile.sh"
export CONNTRACK_SERVICE_FILE="$temporary_root/etc/systemd/system/hguard-conntrack.service"
export HGUARD_CONNTRACK_LOG_TEXT=""

mkdir -p "$HGUARD_PROC_SYS_ROOT/net/netfilter" "$HGUARD_SYS_MODULE_ROOT/nf_conntrack/parameters" "$temporary_root/proc"
printf '1024\n' > "$temporary_root/proc/meminfo"

# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

write_conntrack_fixture() {
  local count="$1"
  local maximum="$2"
  local hashsize="$3"

  printf '%s\n' "$count" > "$(conntrack_count_file)"
  printf '%s\n' "$maximum" > "$(conntrack_max_file)"
  printf '%s\n' "$hashsize" > "$(conntrack_hashsize_file)"
  printf '120\n' > "$(conntrack_timeout_file syn_sent)"
  printf '60\n' > "$(conntrack_timeout_file syn_recv)"
  printf '120\n' > "$(conntrack_timeout_file time_wait)"
}

write_conntrack_fixture 100 32768 8192
assert_equal OK "$(classify_conntrack_health 100 32768 no)" "normal conntrack health"
assert_equal '0.3' "$(conntrack_usage_percent 100 32768)" "normal usage percent"
assert_equal NOTICE "$(classify_conntrack_health 19661 32768 no)" "notice conntrack health"
assert_equal WARNING "$(classify_conntrack_health 26215 32768 no)" "warning conntrack health"
assert_equal CRITICAL "$(classify_conntrack_health 29492 32768 no)" "critical conntrack health"
HGUARD_CONNTRACK_LOG_TEXT='nf_conntrack: table full, dropping packet'
assert_equal CRITICAL "$(classify_conntrack_health 100 65536 "$(conntrack_table_full_state)")" "table full overrides low usage"
HGUARD_CONNTRACK_LOG_TEXT=""

rm -f "$(conntrack_count_file)"
fields="$(conntrack_status_fields)"
IFS='|' read -r count _maximum _usage _hashsize _table_full health <<< "$fields"
assert_equal unavailable "$count" "missing conntrack count is unavailable"
assert_equal UNAVAILABLE "$health" "missing conntrack health is unavailable"

write_conntrack_fixture 100 32768 8192
optimize_conntrack >/dev/null
assert_file_contains "$CONNTRACK_SYSCTL_FILE" 'net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30'
assert_file_contains "$CONNTRACK_SYSCTL_FILE" 'net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20'
assert_file_contains "$CONNTRACK_SYSCTL_FILE" 'net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30'
assert_file_contains "$CONNTRACK_SYSCTL_FILE" 'Netfilter conntrack timeouts; these are not TCP socket TIME_WAIT settings.'
if grep -Fq 'nf_conntrack_max = 65536' "$CONNTRACK_SYSCTL_FILE"; then
  fail "sysctl file still contains a static nf_conntrack_max floor"
fi
assert_file_contains "$CONNTRACK_MODPROBE_FILE" 'options nf_conntrack hashsize=16384'
assert_file_contains "$CONNTRACK_MODULES_FILE" 'nf_conntrack'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'After=systemd-modules-load.service systemd-sysctl.service'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'Before=network-pre.target ufw.service'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'Type=oneshot'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'RemainAfterExit=yes'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'WantedBy=sysinit.target'
assert_file_contains "$CONNTRACK_SERVICE_FILE" 'ExecStart=/bin/bash'
assert_file_contains "$CONNTRACK_HELPER_FILE" 'current_max'
assert_equal 65536 "$(cat "$(conntrack_max_file)")" "runtime max floor raises low values"
assert_equal 30 "$(cat "$(conntrack_timeout_file syn_sent)")" "runtime syn_sent timeout"
assert_equal 20 "$(cat "$(conntrack_timeout_file syn_recv)")" "runtime syn_recv timeout"
assert_equal 30 "$(cat "$(conntrack_timeout_file time_wait)")" "runtime time_wait timeout"
assert_equal active "$(conntrack_runtime_profile_state)" "runtime profile active after optimization"
first_checksum="$(cksum "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE")"
rerun_output_file="$temporary_root/rerun-output.log"
optimize_conntrack > "$rerun_output_file" 2>&1
assert_equal "$first_checksum" "$(cksum "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE")" "conntrack optimization is idempotent"

# A rerun with unchanged files and an already-active runtime profile must
# not reapply anything or claim it did - real-world testing on an already-
# optimized machine showed "Updated nf_conntrack hashsize at runtime" and
# "Applied Hguard conntrack profile" on every single rerun.
if grep -q 'Updated nf_conntrack hashsize at runtime\|Applied Hguard conntrack profile' "$rerun_output_file"; then
  fail "a no-op rerun must not reapply the conntrack profile or claim it did: $(cat "$rerun_output_file")"
fi

pass "a no-op conntrack rerun neither reapplies the runtime profile nor claims it did"

write_conntrack_fixture 100 131072 32768
rm -f "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE"
optimize_conntrack >/dev/null
assert_file_contains "$CONNTRACK_MODPROBE_FILE" 'options nf_conntrack hashsize=32768'
assert_equal 131072 "$(cat "$(conntrack_max_file)")" "runtime max floor preserves high values"
if grep -Fq 'hashsize=16384' "$CONNTRACK_MODPROBE_FILE"; then
  fail "optimization lowered a high existing hashsize"
fi

printf '100\n' > "$(conntrack_count_file)"
printf '65536\n' > "$(conntrack_max_file)"
printf '16384\n' > "$(conntrack_hashsize_file)"
printf '120\n' > "$(conntrack_timeout_file syn_sent)"
printf '60\n' > "$(conntrack_timeout_file syn_recv)"
printf '120\n' > "$(conntrack_timeout_file time_wait)"
assert_equal 'drift detected' "$(conntrack_runtime_profile_state)" "timeout drift is detected"
HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE"
assert_equal active "$(conntrack_runtime_profile_state)" "restart-equivalent helper apply fixes timeout drift"
HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE"
assert_equal active "$(conntrack_runtime_profile_state)" "helper remains idempotent after restart-equivalent apply"

printf '8192\n' > "$(conntrack_max_file)"
HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE"
assert_equal 65536 "$(cat "$(conntrack_max_file)")" "helper raises 8192 max to floor"
HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE"
assert_equal 65536 "$(cat "$(conntrack_max_file)")" "helper preserves 65536 max"
printf '131072\n' > "$(conntrack_max_file)"
HGUARD_PROC_SYS_ROOT="$HGUARD_PROC_SYS_ROOT" bash "$CONNTRACK_HELPER_FILE"
assert_equal 131072 "$(cat "$(conntrack_max_file)")" "helper preserves 131072 max"

custom_sysctl="$temporary_root/etc/sysctl.d/custom.conf"
mkdir -p "$(dirname "$custom_sysctl")"
printf 'net.netfilter.nf_conntrack_max=131072\n' > "$custom_sysctl"
rm -f "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE" "$CONNTRACK_SERVICE_FILE"
optimize_conntrack >/dev/null
[ ! -e "$CONNTRACK_SYSCTL_FILE" ] || fail "foreign sysctl config was overwritten by Hguard"
[ ! -e "$CONNTRACK_MODPROBE_FILE" ] || fail "foreign modprobe config triggered a Hguard write"
[ ! -e "$CONNTRACK_MODULES_FILE" ] || fail "foreign config triggered a Hguard modules-load write"
[ ! -e "$CONNTRACK_SERVICE_FILE" ] || fail "foreign config triggered a Hguard systemd unit write"
assert_file_contains "$custom_sysctl" 'net.netfilter.nf_conntrack_max=131072'

pass "conntrack health, explicit optimization, custom-config protection and idempotency"

# apply_conntrack_runtime_values must skip the helper re-exec when the caller
# reports nothing changed (write_conntrack_files's ATOMIC_WRITE_CHANGED result,
# passed through as this function's 2nd argument).
helper_run_count_file="$temporary_root/helper-run-count"
: > "$helper_run_count_file"
cat > "$CONNTRACK_HELPER_FILE" <<EOF
#!/usr/bin/env bash
printf 'x\n' >> "$helper_run_count_file"
EOF
chmod +x "$CONNTRACK_HELPER_FILE"

apply_conntrack_runtime_values 16384 true
assert_equal 1 "$(wc -l < "$helper_run_count_file" | tr -d ' ')" "files_changed=true runs the helper"

apply_conntrack_runtime_values 16384 false
assert_equal 1 "$(wc -l < "$helper_run_count_file" | tr -d ' ')" "files_changed=false skips the helper"

pass "apply_conntrack_runtime_values skips the helper re-exec when nothing changed"

rm -f "$CONNTRACK_HELPER_FILE"
write_conntrack_helper_file
first_line="$(head -n 1 "$CONNTRACK_HELPER_FILE")"
second_line="$(sed -n '2p' "$CONNTRACK_HELPER_FILE")"
assert_equal "#!/usr/bin/env bash" "$first_line" "conntrack helper has the shebang on line 1"
case "$second_line" in
  '# Managed by Hguard'*) ;;
  *) fail "conntrack helper's ownership marker is not on line 2: ${second_line}" ;;
esac
assert_success managed_file_is_owned "$CONNTRACK_HELPER_FILE"

# Old-format file (marker first, shebang second) must still be recognized.
old_format_file="$temporary_root/old-format.sh"
printf '# Managed by Hguard 0.3.6\n#!/usr/bin/env bash\nset -e\n' > "$old_format_file"
assert_success managed_file_is_owned "$old_format_file"

pass "conntrack helper has the shebang first; the ownership marker is recognized on line 1 or 2"

# optimize_conntrack itself (not the helper called directly) must still pass
# files_changed=true to apply_conntrack_runtime_values when write_conntrack_files
# reports no change but conntrack_runtime_profile_state is not "active" - e.g.
# after a reboot that didn't pick up sysctl.d. Isolate this from the live
# hashsize ratchet (which can make file content drift on its own across real
# calls, confounding a black-box optimize_conntrack rerun) by stubbing both
# collaborators directly - in a subshell, both to keep these redefinitions
# from leaking into any later test (none exist today, but this keeps it
# true by construction rather than by file position) and because an
# earlier apply_conntrack_runtime_values call above, parsed together with
# this later redefinition of the same name, is exactly the shape the
# SC2218 check ("this function is only defined later") flags.
recorded_files_changed_file="$temporary_root/recorded-files-changed"
# Each stub below is called indirectly, by optimize_conntrack on the last
# line of this subshell.
# shellcheck disable=SC2317,SC2329
(
  rm -f "$custom_sysctl"  # an earlier block's foreign file would make optimize_conntrack return early
  write_conntrack_files() { ATOMIC_WRITE_CHANGED="false"; }
  enable_conntrack_service() { :; }
  conntrack_runtime_profile_state() { printf 'drift detected\n'; }
  apply_conntrack_runtime_values() { printf '%s\n' "$2" > "$recorded_files_changed_file"; }
  optimize_conntrack >/dev/null
)
assert_equal "true" "$(cat "$recorded_files_changed_file")" "unchanged files but non-active runtime state still forces files_changed=true"

pass "optimize_conntrack forces a reapply when runtime state is wrong, even if its managed files are unchanged"
