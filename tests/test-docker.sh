#!/bin/bash
# Test docker.sh functionality
# Tests Docker container creation and configuration

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

echo "=== Testing docker.sh ==="
echo ""

# Check if docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP: docker not installed, skipping docker tests"
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
    mode = "docker",
    showBanner = false
}
EOF

echo "=== Testing docker command generation (--test --dry-run) ==="

# Need --test to trigger docker command generation
echo "Test 1: Should generate docker command with --test --dry-run"
output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)

if ! echo "$output" | grep -q "docker run"; then
    echo "FAIL: Should show docker run command"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows docker run command"

echo "Test 2: Should use default image (node:lts-slim)"
if ! echo "$output" | grep -q "node:lts-slim"; then
    echo "FAIL: Should use node:lts-slim image by default"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Uses default image"

echo "Test 3: Should mount intermediary directory"
if ! echo "$output" | grep -q "\-v.*/run/claude-cage/intermediary"; then
    echo "FAIL: Should mount intermediary directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Mounts intermediary directory"

echo "Test 4: Should set working directory to project path"
if ! echo "$output" | grep -q "\-w.*/source"; then
    echo "FAIL: Should set workdir to project path"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Sets working directory to project path"

echo "Test 5: Should run interactively (-it)"
if ! echo "$output" | grep -q "\-it\|--interactive.*--tty"; then
    echo "FAIL: Should run interactively"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Runs interactively"

echo "Test 6: Should set HOME environment"
if ! echo "$output" | grep -q "\-e.*HOME=\|\-\-env.*HOME="; then
    echo "FAIL: Should set HOME env var"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Sets HOME environment"

echo ""
echo "=== Testing docker config options ==="

echo "Test 7: Should accept custom image"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "docker",
    docker = {
        image = "ubuntu:22.04"
    },
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)
if ! echo "$output" | grep -q "ubuntu:22.04"; then
    echo "FAIL: Should use custom image"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Uses custom image"

echo "Test 8: Should accept custom container name"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "docker",
    docker = {
        container = "my-test-container"
    },
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)
if ! echo "$output" | grep -q "my-test-container"; then
    echo "FAIL: Should use custom container name"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Uses custom container name"

echo ""
echo "=== Testing docker with additionalMounts ==="

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "docker",
    additionalMounts = {
        "~/.gitconfig"
    },
    showBanner = false
}
EOF

echo "Test 9: Should include additional mounts"
output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)

if ! echo "$output" | grep -q "\-v.*\.gitconfig"; then
    echo "FAIL: Should include .gitconfig mount"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Includes additional mounts"

echo ""
echo "=== Testing docker run with --rm ==="

echo "Test 10: Should use --rm for cleanup"
if ! echo "$output" | grep -q "\-\-rm"; then
    echo "FAIL: Should include --rm for auto cleanup"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Uses --rm for cleanup"

echo ""
echo "=== Testing docker user mapping ==="

echo "Test 11: Should run as current user"
if ! echo "$output" | grep -q "\-\-user"; then
    echo "FAIL: Should specify --user for UID mapping"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Runs as current user"

echo ""
echo "=== Testing docker network filtering ==="

# Source script to test functions directly
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"

echo "Test 12: generate_docker_iptables_script should generate allowlist rules"
script=$(generate_docker_iptables_script "allowlist" "1.2.3.4:443" "" "" "")
if ! echo "$script" | grep -q "iptables -A OUTPUT -p tcp -d 1.2.3.4 --dport 443 -j ACCEPT"; then
    echo "FAIL: Should generate ACCEPT rule for IP:port"
    echo "Script was:"
    echo "$script"
    exit 1
fi
echo "  PASS: Generates allowlist rules"

echo "Test 13: generate_docker_iptables_script should allow Docker DNS"
if ! echo "$script" | grep -q "127.0.0.11"; then
    echo "FAIL: Should allow Docker DNS (127.0.0.11)"
    exit 1
fi
echo "  PASS: Allows Docker DNS"

echo "Test 14: generate_docker_iptables_script should generate blocklist rules"
script=$(generate_docker_iptables_script "blocklist" "" "" "10.0.0.1" "")
if ! echo "$script" | grep -q "iptables -A OUTPUT -d 10.0.0.1 -j REJECT"; then
    echo "FAIL: Should generate REJECT rule for blocked IP"
    echo "Script was:"
    echo "$script"
    exit 1
fi
echo "  PASS: Generates blocklist rules"

echo "Test 15: blocklist should end with catch-all ACCEPT"
if ! echo "$script" | grep -q "iptables -A OUTPUT -j ACCEPT"; then
    echo "FAIL: Blocklist should have catch-all ACCEPT at end"
    exit 1
fi
echo "  PASS: Blocklist has catch-all ACCEPT"

echo "Test 16: Docker with networkMode should add NET_ADMIN capability"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    mode = "docker",
    networkMode = "allowlist",
    allow = {
        domains = { "github.com:443" }
    },
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --test --dry-run 2>&1)
if ! echo "$output" | grep -q "\-\-cap-add=NET_ADMIN"; then
    echo "FAIL: Should add NET_ADMIN capability"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Adds NET_ADMIN capability"

echo "Test 17: Docker with networkMode should NOT have --user (starts as root)"
if echo "$output" | grep -q "\-\-user"; then
    echo "FAIL: Should NOT have --user when network filtering enabled"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: No --user when network filtering (starts as root)"

echo ""
echo "=== All docker tests passed! ==="
