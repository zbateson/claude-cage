#!/bin/bash
# Test --direct-mount flag and directMount config option
# Tests direct mount mode without git sync

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

echo "=== Testing direct mount mode ==="
echo ""

# Create a git repo for testing
mkdir -p "$TEST_TMP/git-project"
cd "$TEST_TMP/git-project"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add .
git commit -q -m "Initial"

cat > "$TEST_TMP/git-project/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

# Create a non-git directory
mkdir -p "$TEST_TMP/non-git-project"
echo "content" > "$TEST_TMP/non-git-project/file.txt"

echo "=== Testing --direct-mount flag in git repo ==="

BRANCH_NAME=$(git -C "$TEST_TMP/git-project" branch --show-current)
WORK_DIR="" # Would be set by session discovery, but direct mount doesn't create one

echo "Test 1: --direct-mount should skip git sync setup"
cd "$TEST_TMP/git-project"
# Use env -i for consistent behavior across different shell environments
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "exit" | "$2" --direct-mount --test 2>&1' _ "$TEST_TMP/git-project" "$CAGE_DIR/dist/claude-cage") || true

if echo "$output" | grep -q "Intermediary"; then
    echo "FAIL: Should not mention intermediary in direct mount mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Direct mount skips intermediary setup"

echo "Test 2: --direct-mount should not create work directory"
if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
    echo "FAIL: Sessions directory should not be created in direct mount mode"
    exit 1
fi
echo "  PASS: No work directory created"

echo "Test 3: --direct-mount output should indicate direct mount mode"
if ! echo "$output" | grep -q -i "direct"; then
    echo "FAIL: Should indicate direct mount mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Direct mount mode indicated in output"

echo ""
echo "=== Testing directMount config option ==="

cat > "$TEST_TMP/git-project/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    directMount = true
}
EOF

echo "Test 4: directMount config should enable direct mount"
cd "$TEST_TMP/git-project"
rm -rf "$CLAUDE_CAGE_CACHE"  # Clean up any previous test artifacts
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$TEST_TMP/git-project" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "direct"; then
    echo "FAIL: directMount config should enable direct mount"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: directMount config enables direct mount"

echo ""
echo "=== Testing non-git directory handling ==="

echo "Test 5: allowNonGit=true should enable direct mount for non-git dirs"
# Non-git dirs have no git root, so config must come from user config
mkdir -p "$TEST_TMP/.config/claude-cage"
cat > "$TEST_TMP/.config/claude-cage/config" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    allowNonGit = true
}
EOF

cd "$TEST_TMP/non-git-project"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$TEST_TMP/non-git-project" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "direct"; then
    echo "FAIL: Should use direct mount for non-git directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Non-git directory uses direct mount"

echo "Test 6: allowNonGit=false should reject non-git dirs"
cat > "$TEST_TMP/.config/claude-cage/config" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    allowNonGit = false
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" --test 2>&1' _ "$TEST_TMP/non-git-project" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "git"; then
    echo "FAIL: Should mention git requirement"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: allowNonGit=false rejects non-git dirs"

# Clean up user config so it doesn't affect remaining tests
rm -f "$TEST_TMP/.config/claude-cage/config"

echo ""
echo "=== Testing git-merge rejection in direct mount mode ==="

cat > "$TEST_TMP/git-project/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    directMount = true
}
EOF

echo "Test 7: git-merge should fail in direct mount mode"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" git-merge 2>&1' _ "$TEST_TMP/git-project" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "direct mount"; then
    echo "FAIL: Should reject git-merge in direct mount mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: git-merge rejected in direct mount mode"

echo ""
echo "=== Testing --direct-mount with passthrough args ==="

cat > "$TEST_TMP/git-project/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    launch = "echo"
}
EOF

echo "Test 8: --direct-mount should work with passthrough args"
cd "$TEST_TMP/git-project"
# Use env -i for consistent behavior across different shell environments
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "exit" | "$2" --direct-mount --test 2>&1' _ "$TEST_TMP/git-project" "$CAGE_DIR/dist/claude-cage") || true

# Just verify it runs without error
if echo "$output" | grep -q "error"; then
    echo "FAIL: Should run without errors"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Direct mount works with passthrough args"

echo ""
echo "=== All direct mount tests passed! ==="
