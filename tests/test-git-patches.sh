#!/bin/bash
# Test git-patches.sh functionality
# Tests failed patch recovery functions

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing git-patches.sh ==="
echo ""

# Source the script to get functions
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"

echo "Test 1: list_pending_patch_branches returns empty when no patches"
result=$(list_pending_patch_branches "$TEST_TMP/source")
if [ -n "$result" ]; then
    echo "FAIL: Expected empty, got '$result'"
    exit 1
fi
echo "  PASS: Returns empty when no patches"

echo "Test 2: list_pending_patch_branches finds patches for single branch"
mkdir -p "$TEST_TMP/source/claude-cage-failed-patches/main"
echo "patch content" > "$TEST_TMP/source/claude-cage-failed-patches/main/test.patch"
result=$(list_pending_patch_branches "$TEST_TMP/source")
if [ "$result" != "main" ]; then
    echo "FAIL: Expected 'main', got '$result'"
    exit 1
fi
echo "  PASS: Finds patches for single branch"

echo "Test 3: list_pending_patch_branches finds patches across multiple branches"
mkdir -p "$TEST_TMP/source/claude-cage-failed-patches/develop"
mkdir -p "$TEST_TMP/source/claude-cage-failed-patches/feature--foo"
echo "patch" > "$TEST_TMP/source/claude-cage-failed-patches/develop/test.patch"
echo "patch" > "$TEST_TMP/source/claude-cage-failed-patches/feature--foo/test.patch"
result=$(list_pending_patch_branches "$TEST_TMP/source")
if [[ "$result" != *"main"* ]] || [[ "$result" != *"develop"* ]] || [[ "$result" != *"feature/foo"* ]]; then
    echo "FAIL: Expected all three branches, got '$result'"
    exit 1
fi
echo "  PASS: Finds patches across multiple branches"

echo "Test 4: list_pending_patch_branches ignores empty directories"
mkdir -p "$TEST_TMP/source/claude-cage-failed-patches/empty-branch"
result=$(list_pending_patch_branches "$TEST_TMP/source")
if [[ "$result" == *"empty-branch"* ]]; then
    echo "FAIL: Should ignore empty directories"
    exit 1
fi
echo "  PASS: Ignores empty directories"

echo "Test 5: count_patches_for_branch returns correct count"
count=$(count_patches_for_branch "$TEST_TMP/source" "main")
if [ "$count" != "1" ]; then
    echo "FAIL: Expected 1, got '$count'"
    exit 1
fi
echo "  PASS: Returns correct count"

echo "Test 6: count_patches_for_branch handles branch with slash"
count=$(count_patches_for_branch "$TEST_TMP/source" "feature/foo")
if [ "$count" != "1" ]; then
    echo "FAIL: Expected 1 for feature/foo, got '$count'"
    exit 1
fi
echo "  PASS: Handles branch with slash"

echo "Test 7: count_patches_for_branch returns 0 for non-existent branch"
count=$(count_patches_for_branch "$TEST_TMP/source" "nonexistent")
if [ "$count" != "0" ]; then
    echo "FAIL: Expected 0, got '$count'"
    exit 1
fi
echo "  PASS: Returns 0 for non-existent branch"

# Clean up for save_failed_patch tests
rm -rf "$TEST_TMP/source/claude-cage-failed-patches"

echo "Test 8: save_failed_patch creates patch file"
save_failed_patch "$TEST_TMP/source" "diff --git content" "main" "Fix the bug" >/dev/null
patch_files=$(find "$TEST_TMP/source/claude-cage-failed-patches/main" -name "*.patch" 2>/dev/null | wc -l)
if [ "$patch_files" != "1" ]; then
    echo "FAIL: Expected 1 patch file, found $patch_files"
    exit 1
fi
echo "  PASS: Creates patch file"

echo "Test 9: save_failed_patch uses timestamp in filename"
patch_file=$(find "$TEST_TMP/source/claude-cage-failed-patches/main" -name "*.patch" 2>/dev/null | head -1)
if [[ "$patch_file" != *"_Fix_the_bug.patch" ]]; then
    echo "FAIL: Filename should contain subject: $patch_file"
    exit 1
fi
echo "  PASS: Filename includes subject"

echo "Test 10: save_failed_patch sanitizes branch with slash"
save_failed_patch "$TEST_TMP/source" "diff content" "feature/bar" "Add feature" >/dev/null
if [ ! -d "$TEST_TMP/source/claude-cage-failed-patches/feature--bar" ]; then
    echo "FAIL: Should sanitize branch name (feature/bar -> feature--bar)"
    exit 1
fi
echo "  PASS: Sanitizes branch with slash"

echo "Test 11: save_failed_patch preserves patch content"
rm -rf "$TEST_TMP/source/claude-cage-failed-patches"
save_failed_patch "$TEST_TMP/source" "my patch content here" "test" "Test commit" >/dev/null
content=$(cat "$TEST_TMP/source/claude-cage-failed-patches/test/"*.patch)
if [ "$content" != "my patch content here" ]; then
    echo "FAIL: Patch content not preserved"
    exit 1
fi
echo "  PASS: Preserves patch content"

echo "Test 12: save_failed_patch suggests git am (not git apply)"
output=$(save_failed_patch "$TEST_TMP/source" "content" "main" "Test" 2>&1)
if [[ "$output" != *"git am"* ]]; then
    echo "FAIL: Should suggest 'git am', got: $output"
    exit 1
fi
echo "  PASS: Suggests git am"

echo ""
echo "=== All git-patches tests passed! ==="
