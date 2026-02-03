#!/bin/bash
# Test clean and clean-all commands
# Tests cache cleanup functionality

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

# Use test-specific cache and runtime dirs to avoid polluting user's dirs
export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing clean commands ==="
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
    hideConfirmationPrompt = true,
    autoMerge = true
}
EOF

# Compute expected paths
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/work$SOURCE_PATH"
PRE_COMMIT_HOOK="$SOURCE_PATH/.git/hooks/pre-commit.d/claude-cage-$BRANCH_NAME"
POST_COMMIT_HOOK="$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$BRANCH_NAME"

echo "=== Setting up test cage ==="

echo "Test 1: Create cage to have something to clean"
cd "$TEST_TMP/source"
# Use env -i for consistent behavior across different shell environments
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should exist after cage creation"
    exit 1
fi
echo "  PASS: Cage created successfully"

echo "Test 1b: Simulate orphaned hooks (as if session crashed)"
# Normal exit cleans up hooks, so we manually create them to simulate a crash
mkdir -p "$SOURCE_PATH/.git/hooks/pre-commit.d"
mkdir -p "$SOURCE_PATH/.git/hooks/post-commit.d"

cat > "$SOURCE_PATH/.git/hooks/pre-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
[ -d "$HOOK_DIR" ] && for hook in "$HOOK_DIR"/*; do [ -x "$hook" ] && "$hook" "$@"; done
DISPATCHER
chmod +x "$SOURCE_PATH/.git/hooks/pre-commit"

cat > "$SOURCE_PATH/.git/hooks/post-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
[ -d "$HOOK_DIR" ] && for hook in "$HOOK_DIR"/*; do [ -x "$hook" ] && "$hook" "$@"; done
DISPATCHER
chmod +x "$SOURCE_PATH/.git/hooks/post-commit"

cat > "$PRE_COMMIT_HOOK" << EOF
#!/bin/bash
WORK_DIR="$WORK_DIR"
EOF
chmod +x "$PRE_COMMIT_HOOK"

cat > "$POST_COMMIT_HOOK" << EOF
#!/bin/bash
INTERMEDIARY="$INTERMEDIARY_DIR"
EOF
chmod +x "$POST_COMMIT_HOOK"

if [ ! -f "$PRE_COMMIT_HOOK" ] || [ ! -f "$POST_COMMIT_HOOK" ]; then
    echo "FAIL: Failed to create simulated orphaned hooks"
    exit 1
fi
echo "  PASS: Simulated orphaned hooks created"

echo ""
echo "=== Testing clean with --branch flag ==="

echo "Test 2: clean --branch with nonexistent branch should fail"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" clean --branch nonexistent 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q "not found"; then
    echo "FAIL: Should report branch not found"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports nonexistent branch correctly"

echo "Test 3: clean --branch should remove specified branch"
# Answer 'y' to confirmation prompt
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && echo "y" | "$2" clean --branch "'"$BRANCH_NAME"'" >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should be removed after clean"
    exit 1
fi
if [ -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Intermediary directory should be removed after clean"
    exit 1
fi
echo "  PASS: Branch cache removed successfully"

echo "Test 3b: clean should also remove hooks"
if [ -f "$PRE_COMMIT_HOOK" ]; then
    echo "FAIL: pre-commit hook should be removed after clean"
    exit 1
fi
if [ -f "$POST_COMMIT_HOOK" ]; then
    echo "FAIL: post-commit hook should be removed after clean"
    exit 1
fi
echo "  PASS: Hooks removed"

echo ""
echo "=== Testing clean-all ==="

echo "Test 4: Recreate cage for clean-all test"
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should exist after cage recreation"
    exit 1
fi
echo "  PASS: Cage recreated"

echo "Test 5: clean-all should remove all caches"
# Answer 'y' to confirmation
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && echo "y" | "$2" clean-all >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should be removed after clean-all"
    exit 1
fi
echo "  PASS: All caches removed"

echo ""
echo "=== Testing clean with no caches ==="

echo "Test 6: clean with no caches should report nothing to clean"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" clean 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "nothin"; then
    echo "FAIL: Should report nothing to clean"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports no caches correctly"

echo ""
echo "=== Testing dirty work directory warnings ==="

echo "Test 7: Recreate cage and make it dirty"
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

# Make the work directory dirty
echo "dirty change" >> "$WORK_DIR/file.txt"

echo "Test 8: clean should show warning for dirty branch"
# Don't actually clean, just check the output shows warning
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && echo "n" | "$2" clean --branch "'"$BRANCH_NAME"'" 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "uncommitted"; then
    echo "FAIL: Should warn about uncommitted changes"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows uncommitted changes warning"

echo "Test 9: clean-all should show warning for dirty branch"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && echo "n" | "$2" clean-all 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "uncommitted"; then
    echo "FAIL: Should warn about uncommitted changes in branch list"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: clean-all shows dirty warning"

echo ""
echo "=== All clean tests passed! ==="
