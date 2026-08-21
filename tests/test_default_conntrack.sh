#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
cp "$TEST_ROOT/install.sh" "$temporary_root/install.sh"

cat > "$temporary_root/install-core.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALL_LOG"
EOF
chmod +x "$temporary_root/install-core.sh"

export CALL_LOG="$temporary_root/calls.log"
: > "$CALL_LOG"
(
  cd "$temporary_root"
  bash ./install.sh
)
mapfile -t calls < "$CALL_LOG"
assert_equal 2 "${#calls[@]}" "default install invokes core twice"
assert_equal '--optimize-conntrack' "${calls[0]}" "default install applies conntrack profile first"
assert_equal '' "${calls[1]}" "default install then runs full hardening"

: > "$CALL_LOG"
(
  cd "$temporary_root"
  bash ./install.sh --optimize-conntrack
)
mapfile -t calls < "$CALL_LOG"
assert_equal 1 "${#calls[@]}" "standalone conntrack path invokes core once"
assert_equal '--optimize-conntrack' "${calls[0]}" "standalone conntrack argument is preserved"

: > "$CALL_LOG"
(
  cd "$temporary_root"
  bash ./install.sh --help
)
mapfile -t calls < "$CALL_LOG"
assert_equal 1 "${#calls[@]}" "help path invokes core once"
assert_equal '--help' "${calls[0]}" "help does not modify conntrack first"

pass "default install applies conntrack profile before full hardening"
