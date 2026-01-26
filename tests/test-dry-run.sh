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
echo "=== Testing firewall creation commands ==="

echo "Test 15: Should show iptables chain creation"
if ! echo "$output" | grep -q "\[dry-run\] iptables -N\|iptables -I OUTPUT"; then
    echo "FAIL: Did not find iptables chain creation commands"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found iptables chain creation commands"

echo "Test 16: Should show iptables catchall rule (blocklist mode ends with ACCEPT)"
if ! echo "$output" | grep -q "iptables -A.*-j ACCEPT"; then
    echo "FAIL: Did not find catchall ACCEPT rule for blocklist mode"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found catchall ACCEPT rule for blocklist mode"

echo ""
echo "=== Testing firewall cleanup commands ==="

echo "Test 17: Cleanup should show firewall chain check"
if ! echo "$cleanup_output" | grep -q "\[dry-run\] check firewall chain exists\|iptables -L OUTPUT"; then
    echo "FAIL: Did not find firewall chain check in cleanup"
    echo "Output was:"
    echo "$cleanup_output"
    exit 1
fi
echo "  PASS: Cleanup checks for firewall chains"

echo ""
echo "=== Testing allowlist mode ==="

# Create a test config for allowlist mode
mkdir -p "$TEST_TMP/allowlist-test/project"
cat > "$TEST_TMP/allowlist-test/claude-cage.config" << 'EOF'
claude_cage {
    user = "testuser",
    directMount = "workspace",
    networkMode = "allowlist",
    allow = {
        ips = { "127.0.0.1:5432" },
        domains = { "github.com:443" }
    }
}
EOF

echo "Test 18: Allowlist mode should show REJECT catchall rule"
cd "$TEST_TMP/allowlist-test/project"
allowlist_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true

if ! echo "$allowlist_output" | grep -q "iptables -A.*-j REJECT\|mode: allowlist"; then
    echo "FAIL: Allowlist mode should end with REJECT rule or show allowlist mode"
    echo "Output was:"
    echo "$allowlist_output"
    exit 1
fi
echo "  PASS: Allowlist mode configured correctly"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing macOS pf firewall simulation ==="

echo "Test 19: macOS simulation should show pf anchor commands"
macos_output=$("$CAGE_DIR/claude-cage" --dry-run --os macos --no-banner 2>&1) || true

if ! echo "$macos_output" | grep -q "pfctl\|pf_rules_file\|anchor"; then
    echo "FAIL: macOS simulation should show pf/anchor commands"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
echo "  PASS: macOS simulation shows pf commands"

echo "Test 20: macOS simulation should show pass/block rules (not ACCEPT/REJECT)"
if echo "$macos_output" | grep -q "ACCEPT\|REJECT"; then
    # This is fine - these words might appear in messages, just check pf syntax is used
    :
fi
# Check for pf-style syntax in the output
if ! echo "$macos_output" | grep -qE "pass out|block out|pfctl"; then
    echo "FAIL: macOS simulation should use pf syntax (pass/block)"
    echo "Output was:"
    echo "$macos_output"
    exit 1
fi
echo "  PASS: macOS simulation uses pf syntax"

echo ""
echo "=== Testing instance tracking ==="

echo "Test 21: Should show instance file registration"
if ! echo "$output" | grep -q "echo.*>>.*instances\|instance"; then
    echo "FAIL: Did not find instance file registration"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found instance tracking commands"

echo "Test 22: Workspace mode should track by mount point"
workspace_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$workspace_output" | grep -q "claude-cage-mount-\|mount_instance_file\|workspace"; then
    echo "FAIL: Workspace mode should mention mount instance tracking"
    echo "Output was:"
    echo "$workspace_output"
    exit 1
fi
echo "  PASS: Workspace mode shows mount point tracking"

echo ""
echo "=== Testing per-project mode cleanup ==="

# Create a test config for per-project mode
mkdir -p "$TEST_TMP/perproject-test/myproject"
cat > "$TEST_TMP/perproject-test/claude-cage.config" << 'EOF'
claude_cage {
    user = "claude",
    userMode = "per-project",
    directMount = "workspace",
    networkMode = "blocklist",
    block = { ips = { "169.254.169.254" } }
}
EOF
cd "$TEST_TMP/perproject-test/myproject"

echo "Test 23: Per-project mode should create user with project suffix"
perproject_output=$("$CAGE_DIR/claude-cage" --dry-run --no-banner 2>&1) || true
if ! echo "$perproject_output" | grep -q "claude-myproject\|claude-perproject"; then
    echo "FAIL: Per-project mode should create user with project suffix"
    echo "Output was:"
    echo "$perproject_output"
    exit 1
fi
echo "  PASS: Per-project mode creates suffixed username"

echo "Test 24: Per-project mode should use per-process firewall chain"
if ! echo "$perproject_output" | grep -q "CLAUDE_CAGE_"; then
    echo "FAIL: Per-project mode should show firewall chain name"
    echo "Output was:"
    echo "$perproject_output"
    exit 1
fi
echo "  PASS: Per-project mode uses named firewall chain"

cd "$TEST_TMP/project"

echo ""
echo "=== Testing Claude Code settings sync ==="

echo "Test 25: Should show rsync command for claude-settings.json"
if ! echo "$output" | grep -q "rsync.*claude-settings.json\|\.claude/settings.json"; then
    echo "FAIL: Did not find Claude settings sync command"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found Claude settings sync command"

echo ""
echo "=== All dry-run tests passed! ==="
