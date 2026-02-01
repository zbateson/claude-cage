#!/bin/bash
# Test git-sync.sh functionality
# Tests sync_to_source and pipe listener

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
cat > "$TEST_TMP/.claude-cage" << 'EOF'
claude_cage {
    autoMerge = true,
    showBanner = false
}
EOF

# Compute expected paths using the new structure (includes branch name)
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/$BRANCH_NAME/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/$BRANCH_NAME/work$SOURCE_PATH"

echo "Setting up cage..."
cd "$TEST_TMP/source"
"$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
# (inside sandbox, intermediary is mounted at /run/claude-cage/intermediary)
git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"

echo ""
echo "Test 1: Push from work should update intermediary"

# Make a change in work and push
cd "$WORK_DIR"
git config user.email "claude@example.com"
git config user.name "Claude"
echo "new content from claude" > newfile.txt
git add newfile.txt
git commit -m "Add newfile from Claude"
git push origin claude

# Check intermediary has the file
if [ ! -f "$INTERMEDIARY_DIR/newfile.txt" ]; then
    echo "FAIL: newfile.txt not in intermediary after push"
    exit 1
fi
echo "  PASS: Push updated intermediary"

echo "Test 2: Intermediary working tree should be updated (updateInstead)"
content=$(cat "$INTERMEDIARY_DIR/newfile.txt")
if [ "$content" != "new content from claude" ]; then
    echo "FAIL: Intermediary content is wrong: '$content'"
    exit 1
fi
echo "  PASS: Intermediary working tree updated"

echo ""
echo "=== Testing manual merge from intermediary ==="

echo "Test 3: Can manually add intermediary as remote and fetch"
cd "$TEST_TMP/source"
git remote add intermediary "$INTERMEDIARY_DIR"
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
rm -rf "$INTERMEDIARY_DIR" "$WORK_DIR"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"
git -C "$TEST_TMP/source" remote remove intermediary 2>/dev/null || true

cd "$TEST_TMP/source"
"$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"

echo "Test 5: Commit to source should sync to intermediary"
cd "$TEST_TMP/source"
echo "from source" > source-file.txt
git add source-file.txt
git commit -m "Add source-file from source"

# The post-commit hook should have synced this
if [ ! -f "$INTERMEDIARY_DIR/source-file.txt" ]; then
    echo "FAIL: source-file.txt not synced to intermediary"
    echo "Intermediary contents:"
    ls -la "$INTERMEDIARY_DIR/"
    echo "Post-commit hook:"
    cat "$TEST_TMP/source/.git/hooks/post-commit"
    exit 1
fi
echo "  PASS: Source commit synced to intermediary"

echo "Test 6: Work can pull changes from intermediary"
cd "$WORK_DIR"
git pull origin claude

if [ ! -f "$WORK_DIR/source-file.txt" ]; then
    echo "FAIL: source-file.txt not in work after pull"
    exit 1
fi
echo "  PASS: Work pulled changes from intermediary"

echo ""
echo "=== Testing pre-commit hook (mixed commit prevention) ==="

# Create a sensitive file in source
cd "$TEST_TMP/source"
rm -rf "$INTERMEDIARY_DIR" "$WORK_DIR"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"

cat > "$TEST_TMP/.claude-cage" << 'EOF'
claude_cage {
    exclude = { ".env" },
    autoMerge = true,
    showBanner = false
}
EOF

"$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"

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
echo "=== Testing branch-switching sync ==="

# Clean up and recreate for this test
rm -rf "$INTERMEDIARY_DIR" "$WORK_DIR"
rm -f "$TEST_TMP/source/.git/hooks/pre-commit"
rm -f "$TEST_TMP/source/.git/hooks/post-commit"

# Create a fresh source repo with a feature branch
rm -rf "$TEST_TMP/source"
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "original" > file.txt
git add .
git commit -q -m "Initial commit"

# Create and switch to feature branch
git checkout -b feature
echo "feature work" > feature.txt
git add .
git commit -q -m "Feature commit"

# Update paths for feature branch
BRANCH_NAME="feature"
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/$BRANCH_NAME/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/$BRANCH_NAME/work$SOURCE_PATH"

cat > "$TEST_TMP/.claude-cage" << 'EOF'
claude_cage {
    autoMerge = true,
    showBanner = false
}
EOF

# Start cage on feature branch
"$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1

# Fix origin path for testing outside sandbox
git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"

# Make a commit in work
cd "$WORK_DIR"
git config user.email "claude@example.com"
git config user.name "Claude"
echo "claude work" > claude.txt
git add claude.txt
git commit -q -m "Claude's commit"
git push origin claude 2>/dev/null

# Now switch source to master (simulating user switching branches)
cd "$TEST_TMP/source"
git checkout master

echo "Test 10: Source should be on master now"
current=$(git branch --show-current)
if [ "$current" != "master" ]; then
    echo "FAIL: Expected to be on master, but on $current"
    exit 1
fi
echo "  PASS: Source is on master"

# Source the script to get sync_to_source function
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"

echo "Test 11: sync_to_source should apply to feature branch (not master)"
# Call sync_to_source directly with target_branch=feature
sync_to_source "$TEST_TMP/source" "$INTERMEDIARY_DIR" "refs/heads/claude" "feature"

# Check that feature branch has the commit
if ! git -C "$TEST_TMP/source" log feature --oneline | grep -q "Claude's commit"; then
    echo "FAIL: Claude's commit should be on feature branch"
    git -C "$TEST_TMP/source" log feature --oneline
    exit 1
fi
echo "  PASS: Commit applied to feature branch"

echo "Test 12: Master branch should NOT have Claude's commit"
if git -C "$TEST_TMP/source" log master --oneline | grep -q "Claude's commit"; then
    echo "FAIL: Claude's commit should NOT be on master"
    exit 1
fi
echo "  PASS: Master branch unchanged"

echo "Test 13: Source working directory should be untouched (still on master)"
current=$(git -C "$TEST_TMP/source" branch --show-current)
if [ "$current" != "master" ]; then
    echo "FAIL: Source should still be on master, but on $current"
    exit 1
fi
echo "  PASS: Source still on master"

echo "Test 14: Working directory should not have claude.txt (master doesn't have it)"
if [ -f "$TEST_TMP/source/claude.txt" ]; then
    echo "FAIL: claude.txt should not be in working directory (we're on master)"
    exit 1
fi
echo "  PASS: Working directory unchanged"

echo ""
echo "=== All git-sync tests passed! ==="
