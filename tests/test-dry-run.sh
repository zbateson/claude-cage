#!/bin/bash
# Test claude-cage dry-run mode
# This test verifies that dry-run mode outputs expected commands without executing them

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing claude-cage --dry-run ==="
echo ""

# Create a test config
mkdir -p "$TEST_TMP/project"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    directMount = "workspace",
    exclude = {
        name = { ".env", "secrets.json" },
        path = { "config/prod.yml" }
    },
    networkMode = "blocklist",
    block = {
        ips = { "169.254.169.254" },
        networks = { "192.168.0.0/16" }
    },
    allow = {
        ips = { "127.0.0.1:5432", "127.0.0.1:6379" },
        domains = { "api.example.com:443" }
    }
}
EOF

cd "$TEST_TMP/project"

echo "Test 1: Dry-run mode should not require sudo"
output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

echo "Test 2: Output should contain [dry-run] prefixed commands"
if ! echo "$output" | grep -q "\[dry-run\]"; then
    echo "FAIL: No [dry-run] commands found in output"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found [dry-run] prefixed commands"

echo "Test 3: Should show user creation command"
if ! echo "$output" | grep -q "\[dry-run\] adduser.*testuser"; then
    echo "FAIL: Did not find adduser command for testuser"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found adduser command"

echo "Test 4: Should show iptables commands for network rules"
if ! echo "$output" | grep -q "\[dry-run\] iptables"; then
    echo "FAIL: Did not find iptables commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found iptables commands"

echo "Test 5: Should show block rules (169.254.169.254)"
if ! echo "$output" | grep -q "169.254.169.254.*REJECT"; then
    echo "FAIL: Did not find block rule for metadata IP"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found block rule for 169.254.169.254"

echo "Test 6: Should show allow rules (127.0.0.1:5432)"
if ! echo "$output" | grep -q "127.0.0.1.*5432.*ACCEPT"; then
    echo "FAIL: Did not find allow rule for postgres"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found allow rule for postgres port"

echo "Test 7: Should show bindfs mount command"
if ! echo "$output" | grep -q "\[dry-run\] bindfs"; then
    echo "FAIL: Did not find bindfs command"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found bindfs command"

echo "Test 8: Should show mkdir commands"
if ! echo "$output" | grep -q "\[dry-run\] mkdir"; then
    echo "FAIL: Did not find mkdir commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found mkdir commands"

echo "Test 9: Should end with DRY-RUN COMPLETE message"
if ! echo "$output" | grep -q "DRY-RUN COMPLETE"; then
    echo "FAIL: Did not find DRY-RUN COMPLETE message"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found DRY-RUN COMPLETE message"

echo "Test 10: Should display exclude configuration"
if ! echo "$output" | grep -q "Name:.*\.env"; then
    echo "FAIL: Did not find .env in excludes display"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found exclude configuration in display"

echo ""
echo "=== Testing cleanup with dry-run ==="

echo "Test 11: Cleanup mode should work with dry-run"
cleanup_output=$("$CAGE_DIR/claude-cage" --cleanup --dry-run --no-banner 2>&1) || true

if ! echo "$cleanup_output" | grep -q "CLEANUP MODE"; then
    echo "FAIL: Did not enter cleanup mode"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Entered cleanup mode"

if ! echo "$cleanup_output" | grep -q "\[dry-run\]"; then
    echo "FAIL: Cleanup mode should show dry-run commands"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup mode shows dry-run commands"

echo ""
echo "=== Testing cross-platform simulation ==="

# Detect current OS
if [[ "$OSTYPE" == "darwin"* ]]; then
    current_os="macos"
    other_os="linux"
else
    current_os="linux"
    other_os="macos"
fi

echo "Current OS: $current_os, will simulate: $other_os"

echo "Test 12: --os flag should require --dry-run"
os_without_dryrun=$("$CAGE_DIR/claude-cage" --os linux 2>&1) || true
if ! echo "$os_without_dryrun" | grep -q "can only be used with --dry-run"; then
    echo "FAIL: --os without --dry-run should error"
    exit 1
fi
echo "  PASS: --os requires --dry-run"

echo "Test 13: --os should accept 'linux' or 'macos'"
invalid_os=$("$CAGE_DIR/claude-cage" --dry-run --os windows 2>&1) || true
if ! echo "$invalid_os" | grep -q "must be 'linux' or 'macos'"; then
    echo "FAIL: --os should reject invalid OS values"
    exit 1
fi
echo "  PASS: --os rejects invalid values"

echo "Test 14: Simulating $other_os on $current_os"
simulated_output=$("$CAGE_DIR/claude-cage" --dry-run --os "$other_os" --no-banner 2>&1) || true

if ! echo "$simulated_output" | grep -q "Simulating OS: $other_os"; then
    echo "FAIL: Should indicate OS simulation"
    echo "Output was:"
    echo "$simulated_output"
    exit 1
fi
echo "  PASS: Shows OS simulation message"

# Test for OS-specific commands
if [ "$other_os" = "macos" ]; then
    # When simulating macOS, should see dscl commands instead of adduser
    if ! echo "$simulated_output" | grep -q "dscl"; then
        echo "FAIL: macOS simulation should use dscl for user creation"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: macOS simulation uses dscl"

    # Check for pf instead of iptables (in the firewall check message)
    if echo "$simulated_output" | grep -q "\[dry-run\] iptables"; then
        echo "FAIL: macOS simulation should not use iptables"
        exit 1
    fi
    echo "  PASS: macOS simulation does not use iptables"
else
    # When simulating Linux, should see adduser and iptables
    if ! echo "$simulated_output" | grep -q "adduser"; then
        echo "FAIL: Linux simulation should use adduser"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: Linux simulation uses adduser"

    if ! echo "$simulated_output" | grep -q "iptables"; then
        echo "FAIL: Linux simulation should use iptables"
        echo "Output was:"
        echo "$simulated_output"
        exit 1
    fi
    echo "  PASS: Linux simulation uses iptables"
fi

echo ""
echo "=== All dry-run tests passed! ==="
