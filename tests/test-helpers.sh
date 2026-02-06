#!/bin/bash
# Test helpers.sh functionality
# Tests run, run_quiet, dry-run mode, verbose mode

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

echo "=== Testing helpers.sh ==="
echo ""

# Create a minimal test setup
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Compute expected paths using the new structure (includes branch name)
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
# Intermediary is shared across branches (not per-branch)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH"
WORK_DIR="" # Will be populated after cage runs

echo "=== Testing --dry-run mode ==="

echo "Test 1: --dry-run should not create cage directories"
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --dry-run >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: intermediary directory should not be created in dry-run mode"
    exit 1
fi
echo "  PASS: cage directories not created in dry-run"

echo "Test 2: --dry-run should show [dry-run] prefix"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage")

if ! echo "$output" | grep -q "\[dry-run\]"; then
    echo "FAIL: Dry-run output should contain [dry-run] prefix"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found [dry-run] prefix"

echo "Test 3: --dry-run should show git commands"
if ! echo "$output" | grep -q "\[dry-run\] git"; then
    echo "FAIL: Dry-run should show git commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows git commands"

echo ""
echo "=== Testing --verbose mode ==="

# These tests run bwrap, which can be affected by shell environment settings.
# We use env -i with minimal PATH to ensure consistent behavior across environments.
# The test uses --test mode with "exit" piped to stdin to exit immediately.

echo "Test 4: --verbose should show [run] prefix"
verbose_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'echo "exit" | "$1" --verbose --test 2>&1' _ "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$verbose_output" | grep -q "\[run\]"; then
    echo "FAIL: Verbose output should contain [run] prefix"
    echo "Output was:"
    echo "$verbose_output"
    exit 1
fi
echo "  PASS: Found [run] prefix in verbose mode"

# Clean up for next test
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"

echo "Test 5: -v should be alias for --verbose"
v_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'echo "exit" | "$1" -v --test 2>&1' _ "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$v_output" | grep -q "\[run\]"; then
    echo "FAIL: -v should work as --verbose alias"
    exit 1
fi
echo "  PASS: -v works as --verbose alias"

echo ""
echo "=== Testing --debug mode ==="

rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"

echo "Test 6: --debug implies --verbose"
debug_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'echo "exit" | "$1" --debug --test 2>&1' _ "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$debug_output" | grep -q "\[run\]"; then
    echo "FAIL: --debug should imply --verbose"
    exit 1
fi
echo "  PASS: --debug implies --verbose"

echo ""
echo "=== Testing run wrapper behavior ==="

echo "Test 7: Commands should execute successfully without dry-run"
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
# Use --test to get a shell (just exit immediately) rather than trying to launch claude
# Use env -i for consistent behavior across different shell environments
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'echo "exit" | "$1" --test' _ "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

if [ ! -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Intermediary should be created without dry-run"
    exit 1
fi
echo "  PASS: Commands execute without dry-run"

echo ""
echo "=== All helpers tests passed! ==="
