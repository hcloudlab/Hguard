#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

version="$(tr -d '[:space:]' < "$TEST_ROOT/VERSION")"
assert_equal 0.4.0 "$version" "VERSION"
assert_file_contains "$TEST_ROOT/install.sh" 'HGUARD_VERSION="0.4.0"'
# status.sh and uninstall.sh no longer declare their own version (or any
# other HGUARD_* constant) - they source install-core.sh in HGUARD_LIB_MODE
# for it, specifically to prevent this kind of literal from drifting
# between files. Assert that sourcing, not a literal.
assert_file_contains "$TEST_ROOT/install-core.sh" 'HGUARD_VERSION="0.4.0"'
assert_file_contains "$TEST_ROOT/status.sh" 'HGUARD_LIB_MODE=1'
# Intentionally single-quoted: checking the literal source text, not expanding it here.
# shellcheck disable=SC2016
assert_file_contains "$TEST_ROOT/status.sh" '. "${SCRIPT_DIR}/install-core.sh"'
assert_file_contains "$TEST_ROOT/uninstall.sh" 'HGUARD_LIB_MODE=1'
# shellcheck disable=SC2016
assert_file_contains "$TEST_ROOT/uninstall.sh" '. "${SCRIPT_DIR}/install-core.sh"'
assert_file_contains "$TEST_ROOT/README.md" 'Hguard v0.4.0'
assert_file_contains "$TEST_ROOT/README.md" '22.04 LTS | 已完成真实 VPS 验证'
assert_file_contains "$TEST_ROOT/README.md" '24.04 LTS | 已完成真实 VPS 验证'
assert_file_contains "$TEST_ROOT/README.md" '26.04 LTS | 不支持，安装前报错'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" '## [0.3.6] - 2026-08-21'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" 'password and passwordless sudo modes'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" 'conntrack health check'
assert_file_contains "$TEST_ROOT/README.md" 'Conntrack 健康检查'
assert_file_contains "$TEST_ROOT/README.md" 'sudo bash install.sh --optimize-conntrack'
assert_file_contains "$TEST_ROOT/.github/workflows/shell-ci.yml" 'bash tests/run.sh'

old_owner='hexa46656-''creator'
if grep -RIn --exclude-dir=.git "$old_owner" "$TEST_ROOT" >/dev/null; then
  fail "current repository links still use the old owner"
fi

pass "version, documentation, workflow and repository-link metadata"
