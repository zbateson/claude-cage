#!/bin/bash
# Test git-hooks.sh functionality
# Tests hook creation and pipe setup

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

echo "=== Testing git-hooks.sh ==="
echo ""

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add .
git commit -m "Initial commit"

# Create config with autoMerge enabled
cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    exclude = { ".env" },
    autoMerge = true,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Compute expected paths using the new structure (includes branch name)
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/work$SOURCE_PATH"
PIPE_PATH="$CLAUDE_CAGE_RUNTIME/pipes/$BRANCH_NAME$SOURCE_PATH"

echo "Test 1: With autoMerge=true, should create post-receive hook"
cd "$TEST_TMP/source"
# Use --test and immediately exit to avoid trying to launch claude
# Use env -i for consistent behavior across different shell environments
# Pass through CLAUDE_CAGE_CACHE and CLAUDE_CAGE_RUNTIME so paths are correct
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

hook_path="$INTERMEDIARY_DIR/.git/hooks/post-receive"
if [ ! -f "$hook_path" ]; then
    echo "FAIL: post-receive hook not created at $hook_path"
    exit 1
fi
echo "  PASS: post-receive hook created"

echo "Test 2: post-receive hook should be executable"
if [ ! -x "$hook_path" ]; then
    echo "FAIL: post-receive hook is not executable"
    exit 1
fi
echo "  PASS: post-receive hook is executable"

echo "Test 3: post-receive hook should write to pipe"
if ! grep -q "echo.*>" "$hook_path"; then
    echo "FAIL: post-receive hook doesn't write to pipe"
    cat "$hook_path"
    exit 1
fi
echo "  PASS: post-receive hook writes to pipe"

echo "Test 4: Pipe directory structure should be created"
# Note: The actual named pipe is cleaned up on script exit, but the directory structure remains
PIPE_DIR=$(dirname "$PIPE_PATH")
if [ ! -d "$PIPE_DIR" ]; then
    echo "FAIL: Pipe directory not created at $PIPE_DIR"
    exit 1
fi
echo "  PASS: Pipe directory structure created"

echo ""
echo "=== Source hook tests ==="
echo "SKIP: Tests 5-10 - Source hooks are cleaned up on sandbox exit"
echo "      These tests require an active sandbox session"

# NOTE: Tests 5-10 verified source hooks (pre-commit, post-commit) but these
# are cleaned up by cleanup_source_hooks on sandbox exit. To test manually,
# run claude-cage --test and check hooks while sandbox is running.

echo ""
echo "=== Testing autoMerge=false (no hooks) ==="

# Clean up and test with autoMerge=false
rm -rf "$INTERMEDIARY_DIR" "$WORK_DIR"
rm -rf "$PIPE_PATH"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"

cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    autoMerge = false,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Use --test mode to avoid trying to launch claude
# Use env -i for consistent behavior across different shell environments
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

echo "Test 11: With autoMerge=false, should NOT create pipe"
if [ -p "$PIPE_PATH" ]; then
    echo "FAIL: Pipe should not be created when autoMerge=false"
    exit 1
fi
echo "  PASS: No pipe created"

echo "Test 12: With autoMerge=false, should NOT create source hooks"
if [ -f "$TEST_TMP/source/.git/hooks/pre-commit" ]; then
    echo "FAIL: pre-commit hook should not be created when autoMerge=false"
    exit 1
fi
echo "  PASS: No pre-commit hook"

if [ -f "$TEST_TMP/source/.git/hooks/post-commit" ]; then
    echo "FAIL: post-commit hook should not be created when autoMerge=false"
    exit 1
fi
echo "  PASS: No post-commit hook"

echo ""
echo "=== Testing orphaned hook cleanup ==="

# Clean up previous test state
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
rm -rf "$TEST_TMP/source/.git/hooks/pre-commit.d" "$TEST_TMP/source/.git/hooks/post-commit.d"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit" "$TEST_TMP/source/.git/hooks/post-commit"

# Create orphaned hooks (hooks pointing to non-existent work/intermediary dirs)
mkdir -p "$TEST_TMP/source/.git/hooks/pre-commit.d"
mkdir -p "$TEST_TMP/source/.git/hooks/post-commit.d"

# Create dispatcher hooks
cat > "$TEST_TMP/source/.git/hooks/pre-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher: runs all hooks in <hook>.d/
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
DISPATCHER
chmod +x "$TEST_TMP/source/.git/hooks/pre-commit"

cat > "$TEST_TMP/source/.git/hooks/post-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher: runs all hooks in <hook>.d/
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
DISPATCHER
chmod +x "$TEST_TMP/source/.git/hooks/post-commit"

# Create orphaned pre-commit hook (pointing to non-existent work dir)
cat > "$TEST_TMP/source/.git/hooks/pre-commit.d/claude-cage-orphaned" << EOF
#!/bin/bash
WORK_DIR="/nonexistent/path/that/does/not/exist"
TARGET_BRANCH="orphaned"
if [ ! -d "\$WORK_DIR" ]; then
    exit 0
fi
EOF
chmod +x "$TEST_TMP/source/.git/hooks/pre-commit.d/claude-cage-orphaned"

# Create orphaned post-commit hook (pointing to non-existent intermediary)
cat > "$TEST_TMP/source/.git/hooks/post-commit.d/claude-cage-orphaned" << EOF
#!/bin/bash
INTERMEDIARY="/nonexistent/intermediary/path"
TARGET_BRANCH="orphaned"
if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0
fi
EOF
chmod +x "$TEST_TMP/source/.git/hooks/post-commit.d/claude-cage-orphaned"

echo "Test 13: Should detect and remove orphaned pre-commit hook"
cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    autoMerge = false,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Run claude-cage which should clean up orphaned hooks on startup
# Use env -i for consistent behavior across different shell environments
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if [ -f "$TEST_TMP/source/.git/hooks/pre-commit.d/claude-cage-orphaned" ]; then
    echo "FAIL: Orphaned pre-commit hook should have been removed"
    exit 1
fi
echo "  PASS: Orphaned pre-commit hook removed"

echo "Test 14: Should detect and remove orphaned post-commit hook"
if [ -f "$TEST_TMP/source/.git/hooks/post-commit.d/claude-cage-orphaned" ]; then
    echo "FAIL: Orphaned post-commit hook should have been removed"
    exit 1
fi
echo "  PASS: Orphaned post-commit hook removed"

echo "Test 15: Should report cleanup in output"
if ! echo "$output" | grep -q -i "orphaned"; then
    echo "FAIL: Should report orphaned hook cleanup"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports orphaned hook cleanup"

echo "Test 16: Should clean up dispatcher when no hooks remain"
# The dispatchers should be removed since no hooks remain in .d directories
if [ -f "$TEST_TMP/source/.git/hooks/pre-commit" ] && grep -q "claude-cage-dispatcher" "$TEST_TMP/source/.git/hooks/pre-commit"; then
    echo "FAIL: pre-commit dispatcher should have been removed"
    exit 1
fi
echo "  PASS: Empty dispatchers cleaned up"

echo ""
echo "=== All git-hooks tests passed! ==="
