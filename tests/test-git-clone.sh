#!/bin/bash
# Test git-clone.sh functionality
# Tests create_intermediary_clone and related functions

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

echo "=== Testing git-clone.sh ==="
echo ""

# Create a test git repo to act as source
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init
git config user.email "test@example.com"
git config user.name "Test User"

# Create some files
echo "public content" > public.txt
echo "SECRET_KEY=abc123" > .env
mkdir -p config
echo "prod: true" > config/prod.yml
echo "dev: true" > config/dev.yml
git add .
git commit -m "Initial commit"

# Create config with excludes (flat array format for git version)
cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    exclude = { ".env", "config/prod.yml" },
    autoMerge = false,
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

echo "Test 1: Dry-run should show intermediary creation"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q "Buildin' your intermediary"; then
    echo "FAIL: Did not find 'Buildin' your intermediary' message"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found intermediary creation message"

echo "Test 2: Dry-run should show claude branch creation"
if ! echo "$output" | grep -q "Settin' up the claude branch"; then
    echo "FAIL: Did not find claude branch setup message"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found claude branch creation"

echo "Test 3: Dry-run should show exclude patterns"
if ! echo "$output" | grep -q "\.env"; then
    echo "FAIL: Did not find .env in excludes"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found exclude patterns"

echo "Test 4: Dry-run should show receive.denyCurrentBranch config"
if ! echo "$output" | grep -q "receive.denyCurrentBranch"; then
    echo "FAIL: Did not find receive.denyCurrentBranch config"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found receive.denyCurrentBranch config"

echo ""
echo "=== Testing actual intermediary creation ==="

# Compute expected paths using the new structure (includes branch name)
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/branches/$BRANCH_NAME/work$SOURCE_PATH"

# Run without dry-run to actually create the intermediary
echo "Test 5: Create intermediary and work directories"
actual_output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if [ ! -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Intermediary directory not created at $INTERMEDIARY_DIR"
    exit 1
fi
echo "  PASS: Intermediary directory created"

if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory not created at $WORK_DIR"
    exit 1
fi
echo "  PASS: Work directory created"

echo "Test 6: Intermediary should be on claude branch"
branch=$(git -C "$INTERMEDIARY_DIR" branch --show-current)
if [ "$branch" != "claude" ]; then
    echo "FAIL: Intermediary branch is '$branch', expected 'claude'"
    exit 1
fi
echo "  PASS: Intermediary is on claude branch"

echo "Test 7: Work should be on claude branch"
branch=$(git -C "$WORK_DIR" branch --show-current)
if [ "$branch" != "claude" ]; then
    echo "FAIL: Work branch is '$branch', expected 'claude'"
    exit 1
fi
echo "  PASS: Work is on claude branch"

echo "Test 8: Intermediary should have receive.denyCurrentBranch=updateInstead"
config_val=$(git -C "$INTERMEDIARY_DIR" config receive.denyCurrentBranch)
if [ "$config_val" != "updateInstead" ]; then
    echo "FAIL: receive.denyCurrentBranch is '$config_val', expected 'updateInstead'"
    exit 1
fi
echo "  PASS: receive.denyCurrentBranch is set correctly"

echo "Test 9: Intermediary should have receive.denyNonFastForwards=true"
config_val=$(git -C "$INTERMEDIARY_DIR" config receive.denyNonFastForwards)
if [ "$config_val" != "true" ]; then
    echo "FAIL: receive.denyNonFastForwards is '$config_val', expected 'true'"
    exit 1
fi
echo "  PASS: receive.denyNonFastForwards is set correctly"

echo "Test 10: Excluded files should NOT be in intermediary"
if [ -f "$INTERMEDIARY_DIR/.env" ]; then
    echo "FAIL: .env should be excluded from intermediary"
    exit 1
fi
echo "  PASS: .env is excluded"

if [ -f "$INTERMEDIARY_DIR/config/prod.yml" ]; then
    echo "FAIL: config/prod.yml should be excluded from intermediary"
    exit 1
fi
echo "  PASS: config/prod.yml is excluded"

echo "Test 11: Included files SHOULD be in intermediary"
if [ ! -f "$INTERMEDIARY_DIR/public.txt" ]; then
    echo "FAIL: public.txt should be in intermediary"
    exit 1
fi
echo "  PASS: public.txt is included"

if [ ! -f "$INTERMEDIARY_DIR/config/dev.yml" ]; then
    echo "FAIL: config/dev.yml should be in intermediary"
    exit 1
fi
echo "  PASS: config/dev.yml is included"

echo "Test 12: Work directory should match intermediary"
if [ ! -f "$WORK_DIR/public.txt" ]; then
    echo "FAIL: public.txt should be in work"
    exit 1
fi
echo "  PASS: Work directory has included files"

if [ -f "$WORK_DIR/.env" ]; then
    echo "FAIL: .env should NOT be in work"
    exit 1
fi
echo "  PASS: Work directory excludes sensitive files"

echo "Test 13: Work origin should point to cage intermediary path"
origin=$(git -C "$WORK_DIR" remote get-url origin)
expected_origin="/run$SOURCE_PATH"
if [ "$origin" != "$expected_origin" ]; then
    echo "FAIL: Work origin is '$origin', expected '$expected_origin'"
    exit 1
fi
echo "  PASS: Work origin points to /run\$SOURCE_PATH"

echo "Test 14: Intermediary should have clean git history (no excluded file history)"
# Check that .env was never in the git history
history_check=$(git -C "$INTERMEDIARY_DIR" log --all --oneline -- .env 2>&1 || true)
if [ -n "$history_check" ]; then
    echo "FAIL: .env appears in intermediary git history"
    echo "History: $history_check"
    exit 1
fi
echo "  PASS: No excluded files in git history"

echo ""
echo "=== All git-clone tests passed! ==="
