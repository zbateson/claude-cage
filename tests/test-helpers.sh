#!/bin/bash
# Test helpers.sh functionality
# Tests run, run_quiet, dry-run mode, verbose mode

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

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

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

echo "=== Testing --dry-run mode ==="

echo "Test 1: --dry-run should not create .caged directory"
cd "$TEST_TMP/source"
"$CAGE_DIR/dist/claude-cage" --dry-run >/dev/null 2>&1

if [ -d "$TEST_TMP/source/.caged" ]; then
    echo "FAIL: .caged directory should not be created in dry-run mode"
    exit 1
fi
echo "  PASS: .caged not created in dry-run"

echo "Test 2: --dry-run should show [dry-run] prefix"
output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)

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

echo "Test 4: --verbose should show [run] prefix"
verbose_output=$("$CAGE_DIR/dist/claude-cage" --verbose 2>&1) || true

if ! echo "$verbose_output" | grep -q "\[run\]"; then
    echo "FAIL: Verbose output should contain [run] prefix"
    echo "Output was:"
    echo "$verbose_output"
    exit 1
fi
echo "  PASS: Found [run] prefix in verbose mode"

# Clean up for next test
rm -rf "$TEST_TMP/source/.caged"

echo "Test 5: -v should be alias for --verbose"
v_output=$("$CAGE_DIR/dist/claude-cage" -v 2>&1) || true

if ! echo "$v_output" | grep -q "\[run\]"; then
    echo "FAIL: -v should work as --verbose alias"
    exit 1
fi
echo "  PASS: -v works as --verbose alias"

echo ""
echo "=== Testing --debug mode ==="

rm -rf "$TEST_TMP/source/.caged"

echo "Test 6: --debug implies --verbose"
debug_output=$("$CAGE_DIR/dist/claude-cage" --debug 2>&1) || true

if ! echo "$debug_output" | grep -q "\[run\]"; then
    echo "FAIL: --debug should imply --verbose"
    exit 1
fi
echo "  PASS: --debug implies --verbose"

echo ""
echo "=== Testing run wrapper behavior ==="

echo "Test 7: Commands should execute successfully without dry-run"
rm -rf "$TEST_TMP/source/.caged"
"$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1

if [ ! -d "$TEST_TMP/source/.caged/intermediary" ]; then
    echo "FAIL: Intermediary should be created without dry-run"
    exit 1
fi
echo "  PASS: Commands execute without dry-run"

echo ""
echo "=== All helpers tests passed! ==="
