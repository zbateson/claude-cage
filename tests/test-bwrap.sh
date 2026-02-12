#!/bin/bash
# Test bwrap.sh functionality
# Tests bwrap sandbox creation and configuration

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

# Use test-specific cache and runtime dirs to avoid polluting user's dirs
export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export CLAUDE_CAGE_MOUNTED_PIPE="$TEST_TMP/.runtime/claude-cage/test-pipe"
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing bwrap.sh ==="
echo ""

# Check if bwrap is available
if ! command -v bwrap >/dev/null 2>&1; then
    echo "SKIP: bwrap not installed, skipping bwrap tests"
    exit 0
fi

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add .
git commit -q -m "Initial"

cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    mode = "bwrap",
    isolated = true,  -- needed for dry-run test (dirs must exist for non-isolated mounts)
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Capture source branch name for later assertions
SOURCE_BRANCH=$(git -C "$TEST_TMP/source" branch --show-current)

echo "=== Testing bwrap command generation (--test --dry-run) ==="

# Need --test to trigger bwrap command generation
echo "Test 1: Should generate bwrap command with --test --dry-run"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --test --dry-run 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage")

if ! echo "$output" | grep -q "bwrap"; then
    echo "FAIL: Should show bwrap command"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows bwrap command"

echo "Test 2: Should include --ro-bind for system directories"
if ! echo "$output" | grep -q "\-\-ro-bind.*/usr"; then
    echo "FAIL: Should bind /usr read-only"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Binds /usr read-only"

echo "Test 3: Should include --bind for intermediary at /run path"
if ! echo "$output" | grep -q "\-\-bind.*/run.*source"; then
    echo "FAIL: Should bind intermediary at /run path"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Binds intermediary directory"

echo "Test 4: Should set HOME environment variable"
if ! echo "$output" | grep -q "\-\-setenv HOME"; then
    echo "FAIL: Should set HOME env var"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Sets HOME environment"

echo "Test 5: Should include user namespace flags"
if ! echo "$output" | grep -q "\-\-unshare-user"; then
    echo "FAIL: Should unshare user namespace"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Unshares user namespace"

echo "Test 6: Should NOT include PID namespace (breaks Ctrl+C)"
if echo "$output" | grep -q "\-\-unshare-pid"; then
    echo "FAIL: Should NOT unshare PID namespace (causes signal handling issues)"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Does not unshare PID namespace"

echo "Test 7: Should set working directory to project path"
if ! echo "$output" | grep -q "\-\-chdir.*source"; then
    echo "FAIL: Should chdir to project directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Sets working directory to project path"

echo "Test 8: Should include --die-with-parent"
if ! echo "$output" | grep -q "\-\-die-with-parent"; then
    echo "FAIL: Should include --die-with-parent for cleanup"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Includes --die-with-parent"

echo ""
echo "=== Testing bwrap with additionalMounts ==="

cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    mode = "bwrap",
    additionalMounts = {
        "~/.gitconfig",
        { source = "/etc/hosts", as = "/etc/hosts" }
    },
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

echo "Test 9: Should include additional mounts in bwrap command"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --test --dry-run 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage")

if ! echo "$output" | grep -q "\-\-ro-bind.*\.gitconfig"; then
    echo "FAIL: Should include .gitconfig mount"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Includes additional mounts"

echo ""
echo "=== Testing bwrap hostname isolation ==="

echo "Test 10: Should set custom hostname"
if ! echo "$output" | grep -q "\-\-hostname.*caged"; then
    echo "FAIL: Should set caged hostname"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Sets caged hostname"

echo ""
echo "=== Testing actual bwrap execution (--test mode) ==="

# Note: Actual execution tests require user namespaces which may not be
# available in all environments (containers, restricted kernels).
# These tests are run only if bwrap can actually create namespaces.

# Reset config - clean up cache dirs
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    mode = "bwrap",
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

echo "Test 11: --test mode should create cage and attempt to run shell"
test_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "echo INSIDE_CAGE; exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

# Check if bwrap failed due to namespace restrictions
if echo "$test_output" | grep -qE "No permissions to create new namespace|setting up uid map: Permission denied"; then
    echo "  SKIP: User namespaces not available (kernel restriction)"
    echo ""
    echo "=== All bwrap tests passed (execution tests skipped)! ==="
    exit 0
fi

if ! echo "$test_output" | grep -q "INSIDE_CAGE"; then
    echo "FAIL: --test should run commands inside cage"
    echo "Output was:"
    echo "$test_output"
    exit 1
fi
echo "  PASS: --test runs inside cage"

echo "Test 12: Should be able to see files in work directory"
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
test_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "ls -la; exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$test_output" | grep -q "file.txt"; then
    echo "FAIL: Should see file.txt in work directory"
    echo "Output was:"
    echo "$test_output"
    exit 1
fi
echo "  PASS: Can see files in work directory"

echo "Test 13: Should be able to run git commands inside cage"
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
test_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "git status; exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$test_output" | grep -q "On branch $SOURCE_BRANCH"; then
    echo "FAIL: Should be on $SOURCE_BRANCH branch inside cage"
    echo "Output was:"
    echo "$test_output"
    exit 1
fi
echo "  PASS: Can run git commands, on $SOURCE_BRANCH branch"

echo ""
echo "=== All bwrap tests passed! ==="
