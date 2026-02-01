#!/bin/bash
# Test bwrap.sh functionality
# Tests bwrap sandbox creation and configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

# Use test-specific cache and runtime dirs to avoid polluting user's dirs
export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"

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

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "bwrap",
    showBanner = false
}
EOF

echo "=== Testing bwrap command generation (--test --dry-run) ==="

# Need --test to trigger bwrap command generation
echo "Test 1: Should generate bwrap command with --test --dry-run"
output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)

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

echo "Test 3: Should include --bind for work and intermediary directories"
if ! echo "$output" | grep -q "\-\-bind.*/run/claude-cage/intermediary"; then
    echo "FAIL: Should bind intermediary directory"
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

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "bwrap",
    additionalMounts = {
        "~/.gitconfig",
        { source = "/etc/hosts", as = "/etc/hosts" }
    },
    showBanner = false
}
EOF

echo "Test 9: Should include additional mounts in bwrap command"
output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)

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
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "bwrap",
    showBanner = false
}
EOF

echo "Test 11: --test mode should create cage and attempt to run shell"
cd "$TEST_TMP/source"
test_output=$("$CAGE_DIR/dist/claude-cage" --test <<< "echo 'INSIDE_CAGE'; exit" 2>&1) || true

# Check if bwrap failed due to namespace restrictions
if echo "$test_output" | grep -q "No permissions to create new namespace"; then
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
test_output=$("$CAGE_DIR/dist/claude-cage" --test <<< "ls -la; exit" 2>&1) || true

if ! echo "$test_output" | grep -q "file.txt"; then
    echo "FAIL: Should see file.txt in work directory"
    echo "Output was:"
    echo "$test_output"
    exit 1
fi
echo "  PASS: Can see files in work directory"

echo "Test 13: Should be able to run git commands inside cage"
rm -rf "$CLAUDE_CAGE_CACHE" "$CLAUDE_CAGE_RUNTIME"
test_output=$("$CAGE_DIR/dist/claude-cage" --test <<< "git status; exit" 2>&1) || true

if ! echo "$test_output" | grep -q "On branch claude"; then
    echo "FAIL: Should be on claude branch inside cage"
    echo "Output was:"
    echo "$test_output"
    exit 1
fi
echo "  PASS: Can run git commands, on claude branch"

echo ""
echo "=== All bwrap tests passed! ==="
