#!/bin/bash
# Test config.sh functionality
# Tests Lua config parsing, config discovery, option handling

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

# Use test-specific cache and runtime dirs to avoid polluting user's dirs
export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export HOME="$TEST_TMP"

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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/project1" "$CAGE_DIR/dist/claude-cage")
if ! echo "$output" | grep -q "project1/.claude-cage"; then
    echo "FAIL: Should find config in current directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found config in current directory"

echo "Test 2: Should error when no config found (non-interactive)"
mkdir -p "$TEST_TMP/no-config"
setup_git_repo "$TEST_TMP/no-config"

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1 </dev/null' _ "$TEST_TMP/no-config" "$CAGE_DIR/dist/claude-cage") || true
if ! echo "$output" | grep -q "No config found"; then
    echo "FAIL: Should mention missing config"
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/project4" "$CAGE_DIR/dist/claude-cage")
if ! echo "$output" | grep -q "\.env"; then
    echo "FAIL: Should show .env exclude"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "secrets"; then
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/project4" "$CAGE_DIR/dist/claude-cage")
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/project4" "$CAGE_DIR/dist/claude-cage")
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/project4" "$CAGE_DIR/dist/claude-cage")
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
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/myproject" "$CAGE_DIR/dist/claude-cage")
if ! echo "$output" | grep -q "Project:.*myproject"; then
    echo "FAIL: Should derive project name from directory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Derived project name"

echo ""
echo "=== Testing config discovery ==="

echo "Test 8: Should find config at git root from subdirectory"
setup_git_repo "$TEST_TMP/gitroot-test"
mkdir -p "$TEST_TMP/gitroot-test/subdir/deep"
cat > "$TEST_TMP/gitroot-test/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    exclude = { "root-exclude" }
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/gitroot-test/subdir/deep" "$CAGE_DIR/dist/claude-cage")
if ! echo "$output" | grep -q "gitroot-test/.claude-cage"; then
    echo "FAIL: Should find config at git root from subdirectory"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "root-exclude"; then
    echo "FAIL: Should apply excludes from git root config"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found config at git root from subdirectory"

echo ""
echo "=== Testing includeIf config ==="

echo "Test 9: Should merge includeIf and local configs (local overrides scalars)"
mkdir -p "$TEST_TMP/projects/grouped"
setup_git_repo "$TEST_TMP/projects/grouped/myapp"
cat > "$TEST_TMP/projects/grouped/myapp/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    exclude = { "local-exclude" },
    autoMerge = true
}
EOF
# Create includeIf target config
cat > "$TEST_TMP/projects/grouped/claude-cage.config" << 'EOF'
claude_cage {
    exclude = { "grouped-exclude" },
    autoMerge = false
}
EOF
# Create user config with includeIf
mkdir -p "$TEST_TMP/.config/claude-cage"
cat > "$TEST_TMP/.config/claude-cage/config" << EOF
claude_cage {
    includeIf = {
        { dir = "$TEST_TMP/projects/grouped", config = "$TEST_TMP/projects/grouped/claude-cage.config" },
    }
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/projects/grouped/myapp" "$CAGE_DIR/dist/claude-cage")
# Should have both excludes (arrays merge)
if ! echo "$output" | grep -q "grouped-exclude"; then
    echo "FAIL: Should include includeIf excludes"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "local-exclude"; then
    echo "FAIL: Should include local excludes"
    echo "Output was:"
    echo "$output"
    exit 1
fi
# autoMerge from local should override includeIf (scalar)
if ! echo "$output" | grep -q "Auto-merge:.*true"; then
    echo "FAIL: Local config should override includeIf scalar values"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Merged includeIf and local configs correctly"

echo "Test 10: Should show includeIf config in loaded sources"
if ! echo "$output" | grep -q "claude-cage.config"; then
    echo "FAIL: Should list includeIf config in sources"
    echo "Output was:"
    echo "$output"
    exit 1
fi
if ! echo "$output" | grep -q "myapp/.claude-cage"; then
    echo "FAIL: Should list local config in sources"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows includeIf and local config sources"

echo "Test 10b: Should NOT load includeIf for non-matching directory"
setup_git_repo "$TEST_TMP/other-project"
cat > "$TEST_TMP/other-project/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/other-project" "$CAGE_DIR/dist/claude-cage")
if echo "$output" | grep -q "grouped-exclude"; then
    echo "FAIL: Should NOT include excludes from non-matching includeIf"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Non-matching includeIf not loaded"

# Clean up user config so it doesn't affect remaining tests
rm -f "$TEST_TMP/.config/claude-cage/config"

echo ""
echo "=== Testing Lua syntax errors ==="

echo "Test 11: Should report Lua syntax errors"
setup_git_repo "$TEST_TMP/syntax-error"
cat > "$TEST_TMP/syntax-error/.claude-cage" << 'EOF'
claude_cage {
    this is not valid lua syntax
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/syntax-error" "$CAGE_DIR/dist/claude-cage") || true
if ! echo "$output" | grep -qi "error\|wrong\|fix"; then
    echo "FAIL: Should report Lua syntax error"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports Lua syntax errors"

echo ""
echo "=== Testing additionalMounts ==="

echo "Test 12: Should parse additionalMounts"
setup_git_repo "$TEST_TMP/mounts-test"
cat > "$TEST_TMP/mounts-test/.claude-cage" << 'EOF'
claude_cage {
    additionalMounts = {
        "~/.npmrc",
        { source = "/opt/tools", as = "/tools" }
    },
    showBanner = false,
    hideConfirmationPrompt = true
}
EOF

output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" \
    bash -c 'cd "$1" && "$2" --dry-run 2>&1' _ "$TEST_TMP/mounts-test" "$CAGE_DIR/dist/claude-cage")
if ! echo "$output" | grep -q "Additional mounts:\|\.npmrc"; then
    echo "FAIL: Should show additionalMounts"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Parsed additionalMounts"

echo ""
echo "=== All config tests passed! ==="
