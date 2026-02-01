#!/bin/bash
# Test docker.sh functionality
# Tests Docker container creation and configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

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

echo "Test 3: Should mount .caged directory"
if ! echo "$output" | grep -q "\-v.*\.caged"; then
    echo "FAIL: Should mount .caged directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Mounts .caged directory"

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
echo "=== All docker tests passed! ==="
