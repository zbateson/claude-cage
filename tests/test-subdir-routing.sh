#!/bin/bash
# Test subdir auto-routing behavior (Item 1 of the scoped-session plan).
# - is_caged_repo unit tests
# - End-to-end: caged subdir silently routes to git root
# - End-to-end: fresh subdir errors when non-interactive
# - End-to-end: subdir + --scoped leaves scoped flow alone

set -e

unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export CLAUDE_CAGE_MOUNTED_PIPE="$TEST_TMP/.runtime/claude-cage/test-pipe"
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Minimal user-level config so claude-cage doesn't drop into the config-builder
# during end-to-end invocations from fresh repos.
mkdir -p "$TEST_TMP/.config/claude-cage"
cat > "$TEST_TMP/.config/claude-cage/config" << 'EOF'
claude_cage {
    mode = "bwrap",
    isolated = true,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF
export XDG_CONFIG_HOME="$TEST_TMP/.config"

echo "=== Testing subdir auto-routing ==="
echo ""

# ============================================================================
# Unit tests: is_caged_repo
# ============================================================================

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

# Need configured defaults so functions inside don't tripwire
cfg_exclude=""
dry_run=false
verbose=false
debug=false

# Build a fresh git repo with no caged signals
mkdir -p "$TEST_TMP/fresh-repo"
cd "$TEST_TMP/fresh-repo"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "x" > a.txt
git add . && git commit -q -m "Initial"

echo "Test 1: is_caged_repo returns false for a brand-new git repo"
if is_caged_repo "$TEST_TMP/fresh-repo"; then
    echo "FAIL: should not be caged when there's no signal"
    exit 1
fi
echo "  PASS: fresh repo not caged"

echo "Test 2: is_caged_repo returns true when .claude-cage config is present"
echo 'claude_cage { showBanner = false }' > "$TEST_TMP/fresh-repo/.claude-cage"
if ! is_caged_repo "$TEST_TMP/fresh-repo"; then
    echo "FAIL: should be caged when .claude-cage exists"
    exit 1
fi
rm -f "$TEST_TMP/fresh-repo/.claude-cage"
echo "  PASS: .claude-cage qualifies as caged"

echo "Test 3: is_caged_repo returns true when intermediary cache exists"
mkdir -p "$CLAUDE_CAGE_CACHE/intermediary$TEST_TMP/fresh-repo"
if ! is_caged_repo "$TEST_TMP/fresh-repo"; then
    echo "FAIL: should be caged when intermediary cache exists"
    exit 1
fi
rm -rf "$CLAUDE_CAGE_CACHE/intermediary$TEST_TMP/fresh-repo"
echo "  PASS: intermediary cache qualifies as caged"

echo "Test 4: is_caged_repo returns true when repos.list entry exists"
mkdir -p "$CLAUDE_CAGE_CACHE/repos"
_root_hash=$(get_git_root_hash "$TEST_TMP/fresh-repo")
touch "$CLAUDE_CAGE_CACHE/repos/$_root_hash"
if ! is_caged_repo "$TEST_TMP/fresh-repo"; then
    echo "FAIL: should be caged when repos.list exists"
    exit 1
fi
rm -rf "$CLAUDE_CAGE_CACHE/repos"
echo "  PASS: repos.list qualifies as caged"

echo "Test 5: is_caged_repo returns false when no signals after cleanup"
if is_caged_repo "$TEST_TMP/fresh-repo"; then
    echo "FAIL: should not be caged after removing all signals"
    exit 1
fi
echo "  PASS: no signals → not caged"

# ============================================================================
# End-to-end: caged subdir silently routes to git root
# ============================================================================

# Stop sourcing here so dist/claude-cage runs as a fresh process below
cd "$TEST_TMP"

# Build a caged repo with a subdir
mkdir -p "$TEST_TMP/caged-repo/sub/dir"
cd "$TEST_TMP/caged-repo"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "root" > root.txt
echo "nested" > sub/dir/file.txt
git add . && git commit -q -m "Initial"
cat > "$TEST_TMP/caged-repo/.claude-cage" << 'EOF'
claude_cage {
    mode = "bwrap",
    isolated = true,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

echo ""
echo "Test 6: Running from caged subdir silently routes to git root with cd"

# bwrap may not be installed; check before running
if command -v bwrap >/dev/null 2>&1; then
    output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" XDG_CONFIG_HOME="$TEST_TMP/.config" \
        CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
        bash -c 'cd "$1" && "$2" --test --dry-run 2>&1' _ "$TEST_TMP/caged-repo/sub/dir" "$CAGE_DIR/dist/claude-cage" < /dev/null)

    if ! echo "$output" | grep -q "Caged repo detected"; then
        echo "FAIL: Should print 'Caged repo detected' when running from caged subdir"
        echo "Output was:"
        echo "$output"
        exit 1
    fi
    echo "  PASS: prints 'Caged repo detected'"

    echo "Test 7: --chdir reflects the original subdir inside the cage"
    if ! echo "$output" | grep -q "\-\-chdir $TEST_TMP/caged-repo/sub/dir"; then
        echo "FAIL: --chdir should include the subpath sub/dir"
        echo "Output was:"
        echo "$output"
        exit 1
    fi
    echo "  PASS: --chdir lands the shell at the original subdir"
else
    echo "  SKIP: bwrap not installed, skipping bwrap-output assertions (Tests 6-7)"
fi

# ============================================================================
# End-to-end: fresh subdir errors out when non-interactive
# ============================================================================

mkdir -p "$TEST_TMP/fresh-subdir-repo/sub"
cd "$TEST_TMP/fresh-subdir-repo"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "x" > root.txt
git add . && git commit -q -m "Initial"

echo ""
echo "Test 8: Fresh subdir + non-interactive stdin exits with hint"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" XDG_CONFIG_HOME="$TEST_TMP/.config" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --test --dry-run 2>&1; echo "exit=$?"' _ "$TEST_TMP/fresh-subdir-repo/sub" "$CAGE_DIR/dist/claude-cage" < /dev/null) || true

if ! echo "$output" | grep -q "un-caged git repo"; then
    echo "FAIL: Should print hint about un-caged git repo"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "exit=1"; then
    echo "FAIL: Should exit non-zero for fresh subdir in non-interactive mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: fresh subdir in non-interactive mode errors with hint"

# ============================================================================
# End-to-end: subdir + --scoped leaves scoped flow alone
# ============================================================================

echo ""
echo "Test 9: Subdir + --scoped doesn't trigger auto-routing"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" XDG_CONFIG_HOME="$TEST_TMP/.config" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --scoped --test --dry-run 2>&1' _ "$TEST_TMP/caged-repo/sub/dir" "$CAGE_DIR/dist/claude-cage" < /dev/null || true)

if echo "$output" | grep -q "Caged repo detected"; then
    echo "FAIL: Should not run subdir auto-routing when --scoped is passed"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: --scoped bypasses subdir auto-routing"

# ============================================================================
# End-to-end: at git root, no routing message
# ============================================================================

echo ""
echo "Test 10: Running from git root doesn't trigger auto-routing"
if command -v bwrap >/dev/null 2>&1; then
    output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
        CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
        bash -c 'cd "$1" && "$2" --test --dry-run 2>&1' _ "$TEST_TMP/caged-repo" "$CAGE_DIR/dist/claude-cage" < /dev/null)

    if echo "$output" | grep -q "Caged repo detected"; then
        echo "FAIL: Should not announce 'Caged repo detected' when running from git root"
        echo "Output was:"
        echo "$output"
        exit 1
    fi
    echo "  PASS: at git root → no auto-routing message"
else
    echo "  SKIP: bwrap not installed"
fi

echo ""
echo "=== All subdir routing tests passed! ==="
