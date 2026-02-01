#!/bin/bash
# Test git-sync.sh functionality
# Tests sync_to_source and pipe listener

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing git-sync.sh ==="
echo ""

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init
git config user.email "test@example.com"
git config user.name "Test User"
echo "original content" > file.txt
git add .
git commit -m "Initial commit"

# Create config
cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    autoMerge = true,
    showBanner = false
}
EOF

echo "Setting up cage..."
cd "$TEST_TMP/source"
"$CAGE_DIR/dist/claude-cage-git" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
# (inside sandbox, .caged/ is mounted at source, so origin would be source/intermediary)
git -C "$TEST_TMP/source/.caged/work" remote set-url origin "$TEST_TMP/source/.caged/intermediary"

echo ""
echo "Test 1: Push from work should update intermediary"

# Make a change in work and push
cd "$TEST_TMP/source/.caged/work"
git config user.email "claude@example.com"
git config user.name "Claude"
echo "new content from claude" > newfile.txt
git add newfile.txt
git commit -m "Add newfile from Claude"
git push origin claude

# Check intermediary has the file
if [ ! -f "$TEST_TMP/source/.caged/intermediary/newfile.txt" ]; then
    echo "FAIL: newfile.txt not in intermediary after push"
    exit 1
fi
echo "  PASS: Push updated intermediary"

echo "Test 2: Intermediary working tree should be updated (updateInstead)"
content=$(cat "$TEST_TMP/source/.caged/intermediary/newfile.txt")
if [ "$content" != "new content from claude" ]; then
    echo "FAIL: Intermediary content is wrong: '$content'"
    exit 1
fi
echo "  PASS: Intermediary working tree updated"

echo ""
echo "=== Testing manual merge from intermediary ==="

echo "Test 3: Can manually add intermediary as remote and fetch"
cd "$TEST_TMP/source"
git remote add intermediary "$TEST_TMP/source/.caged/intermediary"
git fetch intermediary

if ! git branch -r | grep -q "intermediary/claude"; then
    echo "FAIL: Should see intermediary/claude remote branch"
    git branch -r
    exit 1
fi
echo "  PASS: intermediary remote added and fetched"

echo "Test 4: Manual merge should bring changes to source"
# Need --allow-unrelated-histories since intermediary has fresh history
git merge intermediary/claude -m "Merge claude changes" --allow-unrelated-histories

if [ ! -f "$TEST_TMP/source/newfile.txt" ]; then
    echo "FAIL: newfile.txt not in source after merge"
    exit 1
fi
echo "  PASS: Manual merge brought changes to source"

echo ""
echo "=== Testing source -> intermediary sync ==="

# Clean up and recreate for this test
rm -rf "$TEST_TMP/source/.caged"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"
git -C "$TEST_TMP/source" remote remove intermediary 2>/dev/null || true

cd "$TEST_TMP/source"
"$CAGE_DIR/dist/claude-cage-git" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
git -C "$TEST_TMP/source/.caged/work" remote set-url origin "$TEST_TMP/source/.caged/intermediary"

echo "Test 5: Commit to source should sync to intermediary"
cd "$TEST_TMP/source"
echo "from source" > source-file.txt
git add source-file.txt
git commit -m "Add source-file from source"

# The post-commit hook should have synced this
if [ ! -f "$TEST_TMP/source/.caged/intermediary/source-file.txt" ]; then
    echo "FAIL: source-file.txt not synced to intermediary"
    echo "Intermediary contents:"
    ls -la "$TEST_TMP/source/.caged/intermediary/"
    echo "Post-commit hook:"
    cat "$TEST_TMP/source/.git/hooks/post-commit"
    exit 1
fi
echo "  PASS: Source commit synced to intermediary"

echo "Test 6: Work can pull changes from intermediary"
cd "$TEST_TMP/source/.caged/work"
git pull origin claude

if [ ! -f "$TEST_TMP/source/.caged/work/source-file.txt" ]; then
    echo "FAIL: source-file.txt not in work after pull"
    exit 1
fi
echo "  PASS: Work pulled changes from intermediary"

echo ""
echo "=== Testing pre-commit hook (mixed commit prevention) ==="

# Create a sensitive file in source
cd "$TEST_TMP/source"
rm -rf "$TEST_TMP/source/.caged"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"

cat > "$TEST_TMP/claude-cage.config" << 'EOF'
claude_cage {
    exclude = { ".env" },
    autoMerge = true,
    showBanner = false
}
EOF

"$CAGE_DIR/dist/claude-cage-git" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
git -C "$TEST_TMP/source/.caged/work" remote set-url origin "$TEST_TMP/source/.caged/intermediary"

echo "Test 7: Pre-commit hook should allow commits with only included files"
echo "more content" >> file.txt
git add file.txt
git commit -m "Update file.txt" 2>&1 || {
    echo "FAIL: Commit of included file should succeed"
    exit 1
}
echo "  PASS: Included-only commit succeeded"

echo "Test 8: Pre-commit hook should allow commits with only excluded files"
echo "SECRET=xyz" > .env
git add .env
# This should succeed - it's OK to commit only excluded files
git commit -m "Add .env" 2>&1 || {
    echo "FAIL: Commit of excluded-only file should succeed"
    exit 1
}
echo "  PASS: Excluded-only commit succeeded"

echo "Test 9: Pre-commit hook should REJECT mixed commits"
echo "update" >> file.txt
echo "MORE_SECRET=abc" >> .env
git add file.txt .env

# This should fail
if git commit -m "Mixed commit" 2>&1; then
    echo "FAIL: Mixed commit should have been rejected"
    exit 1
fi
echo "  PASS: Mixed commit rejected"

# Clean up staged files
git reset HEAD file.txt .env
git checkout file.txt .env

echo ""
echo "=== All git-sync tests passed! ==="
