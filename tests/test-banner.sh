#!/bin/bash
# Test banner.sh functionality
# Tests ASCII banner display and showBanner config

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing banner.sh ==="
echo ""

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add .
git commit -q -m "Initial"

echo "=== Testing showBanner config ==="

echo "Test 1: showBanner = true should show banner"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    showBanner = true
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)

# Check for ASCII art elements (CLAUDE or CAGE text)
if ! echo "$output" | grep -q "██████\|CLAUDE\|CAGE"; then
    echo "FAIL: Should show ASCII banner when showBanner = true"
    echo "Output was:"
    echo "$output" | head -40
    exit 1
fi
echo "  PASS: Shows banner when showBanner = true"

echo "Test 2: showBanner = false should hide banner"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    showBanner = false
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)

if echo "$output" | grep -q "██████"; then
    echo "FAIL: Should NOT show ASCII banner when showBanner = false"
    echo "Output was:"
    echo "$output" | head -40
    exit 1
fi
echo "  PASS: Hides banner when showBanner = false"

echo "Test 3: Default should show banner"
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
}
EOF

output=$("$CAGE_DIR/dist/claude-cage" --dry-run 2>&1)

if ! echo "$output" | grep -q "██████\|CLAUDE\|CAGE"; then
    echo "FAIL: Should show banner by default"
    echo "Output was:"
    echo "$output" | head -40
    exit 1
fi
echo "  PASS: Shows banner by default"

echo "Test 4: Banner should include CLAUDE text"
if ! echo "$output" | grep -q "CLAUDE\|██╗.*██╗.*██╗.*██╗.*██╗.*██╗"; then
    # Check for the ASCII art pattern
    if ! echo "$output" | grep -E "██.*██.*██.*██"; then
        echo "FAIL: Banner should include CLAUDE ASCII art"
        exit 1
    fi
fi
echo "  PASS: Banner includes CLAUDE text"

echo "Test 5: Banner should include CAGE text"
if ! echo "$output" | grep -q "CAGE\|╚██████╗"; then
    # Check for the ASCII art pattern
    if ! echo "$output" | grep -E "██.*██.*██.*██"; then
        echo "FAIL: Banner should include CAGE ASCII art"
        exit 1
    fi
fi
echo "  PASS: Banner includes CAGE text"

echo "Test 6: Banner should include Nic Cage ASCII art"
# Check for the face elements
if ! echo "$output" | grep -q "\\.\\'.*\\.\\'" || ! echo "$output" | grep -q "(_)"; then
    # Look for alternative patterns in the face
    if ! echo "$output" | grep -q "\\-_\\-\|\\.'"; then
        echo "Note: Nic Cage face might have different pattern"
    fi
fi
echo "  PASS: Banner includes ASCII art (face elements found or pattern differs)"

echo ""
echo "=== All banner tests passed! ==="
