#!/bin/bash
# Test git-clone.sh functionality
# Tests create_intermediary_clone with bare intermediary + fast-export/fast-import

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

# Use test-specific cache and runtime dirs to avoid polluting user's dirs
export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export CLAUDE_CAGE_MOUNTED_PIPE="$TEST_TMP/.runtime/claude-cage/test-pipe"
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing git-clone.sh ==="
echo ""

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

# Create a test git repo to act as source with multiple commits (for history)
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init
git config user.email "test@test.com"
git config user.name "Test"

# First commit - initial content
echo "initial" > README.md
git add . && git commit -m "Initial"

# Second commit - add files including sensitive and excluded ones
echo "secret" > .env
echo "tmp" > data.tmp
mkdir -p secrets config src/__pycache__ deep/nested/__pycache__
echo "prod" > config/prod.yml
echo "dev" > config/dev.yml
echo "key" > secrets/key.pem
echo "cert" > secrets/cert.pem
echo "keep" > secrets/keep.txt
echo "public" > public.txt
echo "cache" > src/__pycache__/module.pyc
echo "deep" > deep/nested/__pycache__/deep.pyc
echo "log" > app.log
git add -A && git commit -m "Add all files"

# Capture source info
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)

# Expected paths for the new architecture
# Intermediary is shared across branches (NOT per-branch)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH"
# Work dir is still per-branch
SESSION_ID="test-session"; WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$SESSION_ID/work$SOURCE_PATH"

# Set variables needed by create_intermediary_clone
CLAUDE_CAGE_SESSION="$SESSION_ID"
export CLAUDE_CAGE_SESSION
cfg_exclude=".env|config/prod.yml|*.tmp|*.log|**/__pycache__|secrets/**"
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
dry_run=false
verbose=false

echo "Test 1: Dry-run output shows intermediary creation message"
dry_run=true
output=$(create_intermediary_clone "$SOURCE_PATH" 2>&1) || true
dry_run=false

if ! echo "$output" | grep -q "Buildin' your intermediary"; then
    echo "FAIL: Did not find 'Buildin' your intermediary' message"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Found intermediary creation message in dry-run"

# Clean up dry-run artifacts before real run
rm -rf "$CLAUDE_CAGE_CACHE"

echo ""
echo "=== Testing actual intermediary creation ==="

echo "Test 2: Bare intermediary directory created"
create_intermediary_clone "$SOURCE_PATH" >/dev/null 2>&1

if [ ! -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Intermediary directory not created at $INTERMEDIARY_DIR"
    exit 1
fi
# Verify it is a bare repo (has HEAD file directly, no .git subdirectory)
if [ ! -f "$INTERMEDIARY_DIR/HEAD" ]; then
    echo "FAIL: Intermediary is not a bare repo (no HEAD file at top level)"
    exit 1
fi
echo "  PASS: Bare intermediary directory created"

echo "Test 3: Work directory created"
if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory not created at $WORK_DIR"
    exit 1
fi
if [ ! -d "$WORK_DIR/.git" ]; then
    echo "FAIL: Work directory is not a git repo"
    exit 1
fi
echo "  PASS: Work directory created"

echo "Test 4: Branch exists in bare intermediary"
if ! git -C "$INTERMEDIARY_DIR" branch --list | grep -q "$BRANCH_NAME"; then
    echo "FAIL: Branch '$BRANCH_NAME' not found in intermediary"
    echo "Branches: $(git -C "$INTERMEDIARY_DIR" branch --list)"
    exit 1
fi
echo "  PASS: Branch $BRANCH_NAME exists in bare intermediary"

echo "Test 5: Work dir on correct branch"
work_branch=$(git -C "$WORK_DIR" branch --show-current)
if [ "$work_branch" != "$BRANCH_NAME" ]; then
    echo "FAIL: Work branch is '$work_branch', expected '$BRANCH_NAME'"
    exit 1
fi
echo "  PASS: Work is on $BRANCH_NAME branch"

echo "Test 6: receive.denyNonFastForwards=true config set"
config_val=$(git -C "$INTERMEDIARY_DIR" config receive.denyNonFastForwards)
if [ "$config_val" != "true" ]; then
    echo "FAIL: receive.denyNonFastForwards is '$config_val', expected 'true'"
    exit 1
fi
echo "  PASS: receive.denyNonFastForwards is set correctly"

echo "Test 7: Excluded literal files not in intermediary tree (.env, config/prod.yml)"
tree_listing=$(git -C "$INTERMEDIARY_DIR" ls-tree -r --name-only HEAD)

if echo "$tree_listing" | grep -q "^\.env$"; then
    echo "FAIL: .env should be excluded from intermediary tree"
    exit 1
fi
echo "  PASS: .env is excluded"

if echo "$tree_listing" | grep -q "^config/prod\.yml$"; then
    echo "FAIL: config/prod.yml should be excluded from intermediary tree"
    exit 1
fi
echo "  PASS: config/prod.yml is excluded"

echo "Test 8: Wildcard excludes work (*.tmp, *.log)"
if echo "$tree_listing" | grep -q "\.tmp$"; then
    echo "FAIL: *.tmp files should be excluded from intermediary tree"
    echo "Found: $(echo "$tree_listing" | grep '\.tmp$')"
    exit 1
fi
echo "  PASS: *.tmp files are excluded"

if echo "$tree_listing" | grep -q "\.log$"; then
    echo "FAIL: *.log files should be excluded from intermediary tree"
    echo "Found: $(echo "$tree_listing" | grep '\.log$')"
    exit 1
fi
echo "  PASS: *.log files are excluded"

echo "Test 9: Recursive glob excludes work (**/__pycache__)"
if echo "$tree_listing" | grep -q "__pycache__"; then
    echo "FAIL: __pycache__ entries should be excluded from intermediary tree"
    echo "Found: $(echo "$tree_listing" | grep '__pycache__')"
    exit 1
fi
echo "  PASS: **/__pycache__ entries are excluded"

echo "Test 10: Directory excludes work (secrets/**)"
if echo "$tree_listing" | grep -q "^secrets/"; then
    echo "FAIL: secrets/ directory should be excluded from intermediary tree"
    echo "Found: $(echo "$tree_listing" | grep '^secrets/')"
    exit 1
fi
echo "  PASS: secrets/ directory is excluded"

echo "Test 11: Public files preserved in intermediary tree"
if ! echo "$tree_listing" | grep -q "^public\.txt$"; then
    echo "FAIL: public.txt should be in intermediary tree"
    echo "Tree listing:"
    echo "$tree_listing"
    exit 1
fi
echo "  PASS: public.txt is in intermediary tree"

if ! echo "$tree_listing" | grep -q "^config/dev\.yml$"; then
    echo "FAIL: config/dev.yml should be in intermediary tree"
    exit 1
fi
echo "  PASS: config/dev.yml is in intermediary tree"

if ! echo "$tree_listing" | grep -q "^README\.md$"; then
    echo "FAIL: README.md should be in intermediary tree"
    exit 1
fi
echo "  PASS: README.md is in intermediary tree"

echo "Test 12: Work directory has matching content"
if [ ! -f "$WORK_DIR/public.txt" ]; then
    echo "FAIL: public.txt should be in work directory"
    exit 1
fi
echo "  PASS: public.txt is in work directory"

if [ ! -f "$WORK_DIR/config/dev.yml" ]; then
    echo "FAIL: config/dev.yml should be in work directory"
    exit 1
fi
echo "  PASS: config/dev.yml is in work directory"

if [ -f "$WORK_DIR/.env" ]; then
    echo "FAIL: .env should NOT be in work directory"
    exit 1
fi
echo "  PASS: .env is not in work directory"

if [ -d "$WORK_DIR/secrets" ]; then
    echo "FAIL: secrets/ directory should NOT be in work directory"
    exit 1
fi
echo "  PASS: secrets/ directory is not in work directory"

echo "Test 13: Work remote URL points to /run\$INTERMEDIARY_DIR"
origin=$(git -C "$WORK_DIR" remote get-url origin)
expected_origin="/run$INTERMEDIARY_DIR"
if [ "$origin" != "$expected_origin" ]; then
    echo "FAIL: Work origin is '$origin', expected '$expected_origin'"
    exit 1
fi
echo "  PASS: Work origin points to /run\$INTERMEDIARY_DIR"

echo "Test 14: Commit mapping file exists and has entries"
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"
if [ ! -f "$commit_map" ]; then
    echo "FAIL: Commit map file not found at $commit_map"
    exit 1
fi
map_lines=$(wc -l < "$commit_map")
if [ "$map_lines" -lt 1 ]; then
    echo "FAIL: Commit map file is empty (expected at least 1 entry)"
    exit 1
fi
echo "  PASS: Commit map has $map_lines entries"

# Verify commit map format: each line should be "<intermediary-hash> <source-hash>"
while IFS= read -r line; do
    if ! echo "$line" | grep -qE '^[0-9a-f]+ [0-9a-f]+$'; then
        echo "FAIL: Invalid commit map entry: '$line'"
        exit 1
    fi
done < "$commit_map"
echo "  PASS: Commit map entries have correct format"

echo ""
echo "=== Testing catchup with diverged branch ==="

echo "Test 15: Create a branch on source and sync to intermediary"
cd "$SOURCE_PATH"
git checkout -b feature-diverge
echo "feature work" > feature.txt
git add feature.txt && git commit -m "Feature commit"
feature_hash_old=$(git rev-parse HEAD)
git checkout "$BRANCH_NAME"

catchup_intermediary_branches "$SOURCE_PATH" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify feature-diverge >/dev/null 2>&1; then
    echo "FAIL: feature-diverge branch not created in intermediary"
    exit 1
fi
echo "  PASS: feature-diverge branch synced to intermediary"

echo "Test 16: Delete and recreate branch at divergent commit"
git branch -D feature-diverge
# Create from an unrelated point (initial commit, not a descendant of the old tip)
initial_hash=$(git rev-list --reverse HEAD | head -1)
git checkout -b feature-diverge "$initial_hash"
echo "divergent work" > divergent.txt
git add divergent.txt && git commit -m "Divergent commit"
divergent_hash=$(git rev-parse HEAD)
git checkout "$BRANCH_NAME"

echo "Test 17: catchup detects divergence and re-creates branch"
catchup_intermediary_branches "$SOURCE_PATH" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify feature-diverge >/dev/null 2>&1; then
    echo "FAIL: feature-diverge branch missing from intermediary after catchup"
    exit 1
fi
# Verify the intermediary branch maps to the NEW source hash, not the old one
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"
intermediary_diverge_hash=$(git -C "$INTERMEDIARY_DIR" rev-parse feature-diverge)
mapped_source=$(awk -v ih="$intermediary_diverge_hash" '$1 == ih { print $2; exit }' "$commit_map")
if [ "$mapped_source" = "$feature_hash_old" ]; then
    echo "FAIL: intermediary still points to old (pre-divergence) source hash"
    exit 1
fi
echo "  PASS: intermediary branch re-created for diverged source branch"

echo "Test 18: Divergent file exists in intermediary tree"
tree_listing=$(git -C "$INTERMEDIARY_DIR" ls-tree -r --name-only feature-diverge)
if ! echo "$tree_listing" | grep -q "divergent.txt"; then
    echo "FAIL: divergent.txt not found in intermediary feature-diverge tree"
    echo "Tree: $tree_listing"
    exit 1
fi
echo "  PASS: divergent.txt present in re-created branch"

echo ""
echo "=== Testing catchup with converged branches ==="

echo "Test 19: Fast-forward another branch to match master"
cd "$SOURCE_PATH"
git checkout -b converge-test
echo "converge" > converge.txt
git add converge.txt && git commit -m "Converge base"
git checkout "$BRANCH_NAME"

# Sync converge-test into intermediary
catchup_intermediary_branches "$SOURCE_PATH" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify converge-test >/dev/null 2>&1; then
    echo "FAIL: converge-test branch not created in intermediary"
    exit 1
fi
echo "  PASS: converge-test branch synced to intermediary"

echo "Test 20: Add commit to master, fast-forward converge-test to match"
echo "shared" > shared.txt
git add shared.txt && git commit -m "Shared commit on master"
# Sync master's new commit to intermediary
catchup_intermediary_branches "$SOURCE_PATH" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
# Now fast-forward converge-test to same commit as master
git branch -f converge-test "$BRANCH_NAME"
echo "  PASS: converge-test now points to same commit as master on source"

echo "Test 21: catchup updates converged branch ref"
catchup_intermediary_branches "$SOURCE_PATH" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
# Both branches should now point to same commit in intermediary
int_master=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)
int_converge=$(git -C "$INTERMEDIARY_DIR" rev-parse converge-test 2>/dev/null)
if [ "$int_master" != "$int_converge" ]; then
    echo "FAIL: intermediary converge-test ($int_converge) != master ($int_master)"
    exit 1
fi
echo "  PASS: intermediary converge-test updated to match master"

echo ""
echo "=== All git-clone tests passed! ==="
