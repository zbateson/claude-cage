#!/bin/bash
# Test config.sh functionality
# Tests Lua config parsing, config discovery, option handling

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing config.sh ==="
echo ""

# Create a test git repo
setup_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "content" > file.txt
    git add .
    git commit -q -m "Initial"
}

echo "=== Testing config file discovery ==="

echo "Test 1: Should find config in current directory"
setup_git_repo "$TEST_TMP/project1"
cat > "$TEST_TMP/project1/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Configuration loaded from:.*project1/.claude-cage"; then
    echo "FAIL: Should find config in current directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found config in current directory"

echo "Test 2: Should error when no config found"
mkdir -p "$TEST_TMP/no-config"
setup_git_repo "$TEST_TMP/no-config"
cd "$TEST_TMP/no-config"

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1) || true
if ! echo "$output" | grep -q ".claude-cage"; then
    echo "FAIL: Should mention missing config file"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Errors on missing config"

echo ""
echo "=== Testing config options ==="

echo "Test 3: Should parse exclude array"
setup_git_repo "$TEST_TMP/project4"
cat > "$TEST_TMP/project4/.claude-cage" << 'EOF'
claude_cage {
    exclude = { ".env", "secrets/**", "config/prod.yml" },
    showBanner = false
}
EOF

cd "$TEST_TMP/project4"
output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Exclude: .env"; then
    echo "FAIL: Should show .env exclude"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "Exclude: secrets"; then
    echo "FAIL: Should show secrets exclude"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Parsed exclude array"

echo "Test 4: Should parse autoMerge option"
cat > "$TEST_TMP/project4/.claude-cage" << 'EOF'
claude_cage {
    autoMerge = true,
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Auto-merge:.*true"; then
    echo "FAIL: Should show autoMerge = true"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Parsed autoMerge option"

echo "Test 5: Should parse mode option (bwrap vs docker)"
cat > "$TEST_TMP/project4/.claude-cage" << 'EOF'
claude_cage {
    mode = "docker",
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Mode:.*docker"; then
    echo "FAIL: Should show mode = docker"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Parsed mode option"

echo "Test 6: Should default mode to bwrap"
cat > "$TEST_TMP/project4/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Mode:.*bwrap"; then
    echo "FAIL: Default mode should be bwrap"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Default mode is bwrap"

echo ""
echo "=== Testing project name derivation ==="

echo "Test 7: Should derive project name from current directory"
setup_git_repo "$TEST_TMP/myproject"
cat > "$TEST_TMP/myproject/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

cd "$TEST_TMP/myproject"
output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Project:.*myproject"; then
    echo "FAIL: Should derive project name from directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Derived project name"

echo ""
echo "=== Testing --config flag ==="

echo "Test 8: Should accept explicit config path"
setup_git_repo "$TEST_TMP/explicit-test"
cat > "$TEST_TMP/my-custom.config" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

cd "$TEST_TMP/explicit-test"
output=$("$CAGE_DIR/dist/claude-cage" --config "$TEST_TMP/my-custom.config" --dry-run 2>&1)
if ! echo "$output" | grep -q "Configuration loaded from:.*my-custom.config"; then
    echo "FAIL: Should use explicit config path"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Used explicit config path"

echo "Test 9: Should error on invalid explicit config path"
output=$("$CAGE_DIR/dist/claude-cage" --config "/nonexistent/config" --dry-run 2>&1) || true
if ! echo "$output" | grep -qi "ain't there\|not found\|no such"; then
    echo "FAIL: Should error on invalid config path"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Errors on invalid config path"

echo ""
echo "=== Testing Lua syntax errors ==="

echo "Test 10: Should report Lua syntax errors"
setup_git_repo "$TEST_TMP/syntax-error"
cat > "$TEST_TMP/syntax-error/.claude-cage" << 'EOF'
claude_cage {
    this is not valid lua syntax
}
EOF

cd "$TEST_TMP/syntax-error"
output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1) || true
if ! echo "$output" | grep -qi "error\|wrong\|fix"; then
    echo "FAIL: Should report Lua syntax error"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports Lua syntax errors"

echo ""
echo "=== Testing additionalMounts ==="

echo "Test 11: Should parse additionalMounts"
setup_git_repo "$TEST_TMP/mounts-test"
cat > "$TEST_TMP/mounts-test/.claude-cage" << 'EOF'
claude_cage {
    additionalMounts = {
        "~/.npmrc",
        { source = "/opt/tools", as = "/tools" }
    },
    showBanner = false
}
EOF

cd "$TEST_TMP/mounts-test"
output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)
if ! echo "$output" | grep -q "Additional mounts:\|\.npmrc"; then
    echo "FAIL: Should show additionalMounts"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Parsed additionalMounts"

echo ""
echo "=== All config tests passed! ==="
