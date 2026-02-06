#!/bin/bash
# Run all claude-cage tests

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "  claude-cage test suite"
echo "========================================"
echo ""

# Track results
PASSED=0
FAILED=0

run_test() {
    local test_script="$1"
    local test_name=$(basename "$test_script" .sh)

    echo "----------------------------------------"
    echo "Running: $test_name"
    echo "----------------------------------------"

    if bash "$test_script"; then
        echo ""
        echo ">>> $test_name: PASSED"
        PASSED=$((PASSED + 1))
    else
        echo ""
        echo ">>> $test_name: FAILED"
        FAILED=$((FAILED + 1))
    fi
    echo ""
}

# Run each test
run_test "$SCRIPT_DIR/test-helpers.sh"
run_test "$SCRIPT_DIR/test-config.sh"
run_test "$SCRIPT_DIR/test-banner.sh"
run_test "$SCRIPT_DIR/test-git-clone.sh"
run_test "$SCRIPT_DIR/test-git-filter-stream.sh"
run_test "$SCRIPT_DIR/test-git-hooks.sh"
run_test "$SCRIPT_DIR/test-git-patches.sh"
run_test "$SCRIPT_DIR/test-git-sync.sh"
run_test "$SCRIPT_DIR/test-network.sh"
run_test "$SCRIPT_DIR/test-bwrap.sh"
run_test "$SCRIPT_DIR/test-docker.sh"
run_test "$SCRIPT_DIR/test-clean.sh"
run_test "$SCRIPT_DIR/test-direct-mount.sh"

# Summary
echo "========================================"
echo "  Test Summary"
echo "========================================"
echo "  Passed: $PASSED"
echo "  Failed: $FAILED"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi

echo ""
echo "All tests passed!"
