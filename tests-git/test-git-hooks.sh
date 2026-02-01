#!/bin/bash
# Test git-hooks.sh functionality
# Tests hook creation and pipe setup

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

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
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    exclude = { ".env" },
    autoMerge = true,
    showBanner = false
}
EOF

echo "Test 1: With autoMerge=true, should create post-receive hook"
cd "$TEST_TMP/source"
output=$("$CAGE_DIR/dist/claude-cage-git" 2>&1) || true

hook_path="$TEST_TMP/source/.caged/intermediary/.git/hooks/post-receive"
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

echo "Test 4: Named pipe should be created"
pipe_path="$TEST_TMP/source/.caged/.pipe"
if [ ! -p "$pipe_path" ]; then
    echo "FAIL: Named pipe not created at $pipe_path"
    exit 1
fi
echo "  PASS: Named pipe created"

echo "Test 5: Source repo should have pre-commit hook"
pre_commit="$TEST_TMP/source/.git/hooks/pre-commit"
if [ ! -f "$pre_commit" ]; then
    echo "FAIL: pre-commit hook not created on source"
    exit 1
fi
echo "  PASS: pre-commit hook created"

echo "Test 6: pre-commit hook should check for mixed commits"
if ! grep -q "Mixed commit" "$pre_commit"; then
    echo "FAIL: pre-commit hook doesn't check for mixed commits"
    cat "$pre_commit"
    exit 1
fi
echo "  PASS: pre-commit hook checks for mixed commits"

echo "Test 7: pre-commit hook should have exclude patterns"
if ! grep -q ".env" "$pre_commit"; then
    echo "FAIL: pre-commit hook doesn't include .env pattern"
    cat "$pre_commit"
    exit 1
fi
echo "  PASS: pre-commit hook has exclude patterns"

echo "Test 8: Source repo should have post-commit hook"
post_commit="$TEST_TMP/source/.git/hooks/post-commit"
if [ ! -f "$post_commit" ]; then
    echo "FAIL: post-commit hook not created on source"
    exit 1
fi
echo "  PASS: post-commit hook created"

echo "Test 9: post-commit hook should apply to claude branch"
if ! grep -q "git checkout claude" "$post_commit"; then
    echo "FAIL: post-commit hook doesn't checkout claude branch"
    cat "$post_commit"
    exit 1
fi
echo "  PASS: post-commit hook targets claude branch"

echo "Test 10: post-commit hook should use format-patch"
if ! grep -q "format-patch" "$post_commit"; then
    echo "FAIL: post-commit hook doesn't use format-patch"
    cat "$post_commit"
    exit 1
fi
echo "  PASS: post-commit hook uses format-patch"

echo ""
echo "=== Testing autoMerge=false (no hooks) ==="

# Clean up and test with autoMerge=false
rm -rf "$TEST_TMP/source/.caged"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    autoMerge = false,
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage-git" 2>&1) || true

echo "Test 11: With autoMerge=false, should NOT create pipe"
if [ -p "$TEST_TMP/source/.caged/.pipe" ]; then
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
echo "=== All git-hooks tests passed! ==="
