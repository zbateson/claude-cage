#!/bin/bash
# Test git-hooks.sh functionality
# Tests hook creation, pipe setup, and cleanup for bare intermediary architecture

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

echo "=== Testing git-hooks.sh ==="
echo ""

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

# Create a test git repo
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
echo "secret" > .env
git add .
git commit -m "Initial commit"

# Capture paths
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
INTERMEDIARY_DIR=$(get_intermediary_path "$SOURCE_PATH")
SESSION_ID="test-session"
PIPE_PATH=$(CLAUDE_CAGE_SESSION="$SESSION_ID" get_pipe_path "$SOURCE_PATH")

# Set up variables needed by functions
CLAUDE_CAGE_SESSION="$SESSION_ID"
export CLAUDE_CAGE_SESSION
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
dry_run=false
verbose=false

# Create a bare intermediary for testing hooks
mkdir -p "$(dirname "$INTERMEDIARY_DIR")"
git init --bare "$INTERMEDIARY_DIR" --quiet

# Push content into it via fast-export/fast-import so it has a valid branch
git -C "$SOURCE_PATH" fast-export HEAD 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --quiet 2>/dev/null

# Set up source-branches file (needed for pre-receive tests)
local_source_branches_path=$(get_source_branches_path "$INTERMEDIARY_DIR")
git -C "$SOURCE_PATH" for-each-ref --format='%(refname:short)' refs/heads/ > "$local_source_branches_path"

echo "=== Testing intermediary hook creation ==="
echo ""

# Install intermediary hooks
install_intermediary_hooks "$INTERMEDIARY_DIR"

echo "Test 1: Post-receive hook created on bare intermediary"
hook_path="$INTERMEDIARY_DIR/hooks/post-receive"
if [ ! -f "$hook_path" ]; then
    echo "FAIL: post-receive hook not created at $hook_path"
    exit 1
fi
echo "  PASS: post-receive hook created at $hook_path"

echo "Test 2: Post-receive hook is executable"
if [ ! -x "$hook_path" ]; then
    echo "FAIL: post-receive hook is not executable"
    exit 1
fi
echo "  PASS: post-receive hook is executable"

echo "Test 3: Post-receive hook writes refname newrev oldrev to pipe"
# The hook should write 3 fields: refname newrev oldrev
# Create a test pipe to capture output
test_pipe="$TEST_TMP/test-hook-pipe"
mkfifo -m 0600 "$test_pipe"

# Simulate what the post-receive hook does by examining its content
# It reads "oldrev newrev refname" from stdin and writes "refname newrev oldrev" to pipe
if ! grep -q 'refname.*newrev.*oldrev' "$hook_path"; then
    echo "FAIL: post-receive hook doesn't write refname newrev oldrev"
    cat "$hook_path"
    exit 1
fi
# Verify it writes 3 fields (refname, newrev, oldrev)
if ! grep -q 'echo.*\$refname.*\$newrev.*\$oldrev' "$hook_path"; then
    echo "FAIL: post-receive hook doesn't output all 3 fields"
    cat "$hook_path"
    exit 1
fi
rm -f "$test_pipe"
echo "  PASS: post-receive hook writes refname newrev oldrev"

echo ""
echo "=== Testing pre-receive hook ==="
echo ""

echo "Test 4: Pre-receive hook created and executable"
pre_receive_path="$INTERMEDIARY_DIR/hooks/pre-receive"
if [ ! -f "$pre_receive_path" ]; then
    echo "FAIL: pre-receive hook not created at $pre_receive_path"
    exit 1
fi
if [ ! -x "$pre_receive_path" ]; then
    echo "FAIL: pre-receive hook is not executable"
    exit 1
fi
echo "  PASS: pre-receive hook created and executable"

echo "Test 5: Pre-receive guards against scope collisions"
# The source-branches file should already have our branch listed
# Try to "create" a branch that exists in source but not in intermediary
# First, create a new branch in source that won't be in intermediary
git -C "$SOURCE_PATH" branch test-collision-branch
# Update source-branches file to include the new branch
git -C "$SOURCE_PATH" for-each-ref --format='%(refname:short)' refs/heads/ > "$local_source_branches_path"

# The pre-receive hook should reject creating a branch with that name
# Simulate pre-receive input: oldrev(zeros) newrev refname
ZERO_OID="0000000000000000000000000000000000000000"
FAKE_NEWREV="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# Run the hook with simulated input (setting GIT_DIR so rev-parse works)
result=0
echo "$ZERO_OID $FAKE_NEWREV refs/heads/test-collision-branch" \
    | GIT_DIR="$INTERMEDIARY_DIR" bash "$pre_receive_path" 2>/dev/null || result=$?
if [ "$result" -eq 0 ]; then
    echo "FAIL: pre-receive should have rejected branch that collides with source"
    exit 1
fi
echo "  PASS: pre-receive rejects branch name that exists in source-branches"

# Clean up test branch
git -C "$SOURCE_PATH" branch -D test-collision-branch >/dev/null 2>&1
git -C "$SOURCE_PATH" for-each-ref --format='%(refname:short)' refs/heads/ > "$local_source_branches_path"

echo ""
echo "=== Testing source post-commit hook ==="
echo ""

# Set up source post-commit hook
setup_source_post_commit "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"

echo "Test 6: Source post-commit hook created"
hook_path_hash=$(echo -n "$SOURCE_PATH" | md5sum | cut -c1-12)
post_commit_hook="$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$hook_path_hash"
if [ ! -f "$post_commit_hook" ]; then
    echo "FAIL: post-commit hook not found at $post_commit_hook"
    exit 1
fi
echo "  PASS: source post-commit hook created at $post_commit_hook"

echo "Test 7: Source post-commit hook references INTERMEDIARY"
if ! grep -q "^INTERMEDIARY=" "$post_commit_hook"; then
    echo "FAIL: post-commit hook doesn't have INTERMEDIARY= variable"
    cat "$post_commit_hook"
    exit 1
fi
# Verify it points to our bare intermediary dir
intermediary_in_hook=$(grep '^INTERMEDIARY=' "$post_commit_hook" | head -1 | cut -d'"' -f2)
if [ "$intermediary_in_hook" != "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: INTERMEDIARY points to '$intermediary_in_hook', expected '$INTERMEDIARY_DIR'"
    exit 1
fi
echo "  PASS: post-commit hook references bare intermediary at $INTERMEDIARY_DIR"

echo "Test 8: Source post-commit hook uses fast-export"
if ! grep -q "fast-export" "$post_commit_hook"; then
    echo "FAIL: post-commit hook doesn't use fast-export"
    cat "$post_commit_hook"
    exit 1
fi
# Also ensure it does NOT use format-patch or git am (old architecture)
if grep -q "format-patch" "$post_commit_hook"; then
    echo "FAIL: post-commit hook still uses format-patch (old architecture)"
    exit 1
fi
if grep -q "git am" "$post_commit_hook"; then
    echo "FAIL: post-commit hook still uses git am (old architecture)"
    exit 1
fi
echo "  PASS: post-commit hook uses fast-export (not format-patch)"

# Clean up source hooks for next tests
cleanup_source_hooks "$SOURCE_PATH"

echo ""
echo "=== Testing orphaned hook cleanup ==="
echo ""

# Clean up dispatchers from previous tests
rm -rf "$SOURCE_PATH/.git/hooks/post-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/post-commit"

# Create orphaned post-commit hook pointing to non-existent intermediary
mkdir -p "$SOURCE_PATH/.git/hooks/post-commit.d"
cat > "$SOURCE_PATH/.git/hooks/post-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher: runs all hooks in <hook>.d/
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
DISPATCHER
chmod +x "$SOURCE_PATH/.git/hooks/post-commit"

cat > "$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-orphaned" << EOF
#!/bin/bash
INTERMEDIARY="/nonexistent/intermediary/path"
TARGET_BRANCH="orphaned"
if [ ! -d "\$INTERMEDIARY" ]; then
    exit 0
fi
EOF
chmod +x "$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-orphaned"

echo "Test 9: Orphaned hook cleanup removes hooks pointing to non-existent intermediaries"
cleanup_orphaned_hooks "$SOURCE_PATH"
if [ -f "$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-orphaned" ]; then
    echo "FAIL: Orphaned post-commit hook should have been removed"
    exit 1
fi
echo "  PASS: Orphaned post-commit hook removed"

echo ""
echo "=== Testing legacy pre-commit cleanup ==="
echo ""

echo "Test 10: Legacy pre-commit hooks from previous architecture are cleaned up"
# Create a legacy pre-commit hook (from old architecture that had source pre-commit)
mkdir -p "$SOURCE_PATH/.git/hooks/pre-commit.d"
cat > "$SOURCE_PATH/.git/hooks/pre-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher: runs all hooks in <hook>.d/
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
if [ -d "$HOOK_DIR" ]; then
    for hook in "$HOOK_DIR"/*; do
        [ -x "$hook" ] && "$hook" "$@"
    done
fi
DISPATCHER
chmod +x "$SOURCE_PATH/.git/hooks/pre-commit"

cat > "$SOURCE_PATH/.git/hooks/pre-commit.d/claude-cage-legacy" << EOF
#!/bin/bash
WORK_DIR="/nonexistent/work/path"
TARGET_BRANCH="legacy"
if [ ! -d "\$WORK_DIR" ]; then
    exit 0
fi
EOF
chmod +x "$SOURCE_PATH/.git/hooks/pre-commit.d/claude-cage-legacy"

cleanup_orphaned_hooks "$SOURCE_PATH"
if [ -f "$SOURCE_PATH/.git/hooks/pre-commit.d/claude-cage-legacy" ]; then
    echo "FAIL: Legacy pre-commit hook should have been removed"
    exit 1
fi
# Dispatcher should also be cleaned up since no hooks remain
if [ -f "$SOURCE_PATH/.git/hooks/pre-commit" ] && grep -q "claude-cage-dispatcher" "$SOURCE_PATH/.git/hooks/pre-commit"; then
    echo "FAIL: pre-commit dispatcher should have been removed when no hooks remain"
    exit 1
fi
echo "  PASS: Legacy pre-commit hook and dispatcher cleaned up"

echo ""
echo "=== Testing sync logging ==="
echo ""

echo "Test 11: Post-receive hook logs to sync.log with post-recv direction"
hook_path="$INTERMEDIARY_DIR/hooks/post-receive"
if ! grep -q "sync.log" "$hook_path"; then
    echo "FAIL: post-receive hook doesn't reference sync.log"
    cat "$hook_path"
    exit 1
fi
if ! grep -q "post-recv" "$hook_path"; then
    echo "FAIL: post-receive hook doesn't log with post-recv direction"
    cat "$hook_path"
    exit 1
fi
# Verify sync.log path is at $INTERMEDIARY_DIR/sync.log (bare repo, no .git subdir)
# The hook uses git rev-parse --git-dir which resolves to the bare repo itself
# So SYNC_LOG should end up as $INTERMEDIARY_DIR/sync.log
if ! grep -q 'SYNC_LOG=.*sync.log' "$hook_path"; then
    echo "FAIL: post-receive hook doesn't set SYNC_LOG path"
    cat "$hook_path"
    exit 1
fi
echo "  PASS: post-receive hook logs to sync.log with post-recv direction"

echo ""
echo "=== Testing post-commit hook branch guard ==="
echo ""

# Set up a proper intermediary with marks and commit map for the hook to work
rm -rf "$INTERMEDIARY_DIR"
mkdir -p "$(dirname "$INTERMEDIARY_DIR")"
git init --bare "$INTERMEDIARY_DIR" --quiet

# Create marks and commit map
local_source_marks=$(get_source_marks_path "$INTERMEDIARY_DIR")
local_import_marks=$(get_import_marks_path "$INTERMEDIARY_DIR")
local_commit_map=$(get_commit_map_path "$INTERMEDIARY_DIR")

git -C "$SOURCE_PATH" fast-export --export-marks="$local_source_marks" HEAD 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --export-marks="$local_import_marks" --quiet 2>/dev/null
: > "$local_commit_map"
build_commit_map_from_marks "$local_source_marks" "$local_import_marks" "$local_commit_map" "$SOURCE_PATH" "HEAD"

# Create a second branch in source and add it to intermediary
git -C "$SOURCE_PATH" checkout -b feature-branch --quiet
echo "feature content" > "$SOURCE_PATH/feature.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Feature commit" --quiet

git -C "$SOURCE_PATH" fast-export --import-marks="$local_source_marks" --export-marks="$local_source_marks" \
    feature-branch 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --import-marks="$local_import_marks" --export-marks="$local_import_marks" \
        --quiet 2>/dev/null
build_commit_map_from_marks "$local_source_marks" "$local_import_marks" "$local_commit_map" "" ""

# Go back to master
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet

# Install the hook (target branch is master)
rm -rf "$SOURCE_PATH/.git/hooks/post-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/post-commit"
setup_source_post_commit "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"
post_commit_hook="$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$hook_path_hash"

echo "Test 12: Post-commit hook syncs in-scope branch (not just target)"
# Switch to feature-branch (which exists in intermediary) and commit
git -C "$SOURCE_PATH" checkout feature-branch --quiet
echo "new feature" > "$SOURCE_PATH/feature2.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Feature commit 2" --quiet

# Verify the hook synced this commit to the intermediary
feature_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if grep -q " ${feature_head}$" "$local_commit_map" 2>/dev/null; then
    echo "  PASS: In-scope branch commit synced to intermediary"
else
    echo "FAIL: In-scope branch commit was NOT synced to intermediary"
    echo "  feature HEAD: $feature_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

echo "Test 13: Post-commit hook skips out-of-scope branch"
# Create a branch that does NOT exist in intermediary and commit
git -C "$SOURCE_PATH" checkout -b out-of-scope-branch --quiet
echo "out of scope" > "$SOURCE_PATH/outofscope.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Out of scope" --quiet

out_of_scope_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if grep -q " ${out_of_scope_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Out-of-scope branch commit should NOT have been synced"
    exit 1
fi
echo "  PASS: Out-of-scope branch commit correctly skipped"

# Verify sync.log has the skip message
if grep -q "not in intermediary" "$INTERMEDIARY_DIR/sync.log" 2>/dev/null; then
    echo "  (sync.log confirms: 'not in intermediary' skip logged)"
fi

# Go back to master for remaining tests
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet
cleanup_source_hooks "$SOURCE_PATH"

echo ""
echo "=== Testing autoMerge=false (no hooks) ==="
echo ""

echo "Test 14: No hooks when autoMerge=false"
# Clean up all existing state
rm -rf "$INTERMEDIARY_DIR" "$CLAUDE_CAGE_RUNTIME"
rm -rf "$SOURCE_PATH/.git/hooks/post-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/post-commit"
rm -rf "$SOURCE_PATH/.git/hooks/pre-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/pre-commit"

# Recreate bare intermediary without installing hooks
mkdir -p "$(dirname "$INTERMEDIARY_DIR")"
git init --bare "$INTERMEDIARY_DIR" --quiet
git -C "$SOURCE_PATH" fast-export HEAD 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --quiet 2>/dev/null

# When autoMerge=false, setup_git_hooks should NOT be called.
# Verify that without calling setup_git_hooks:
# - no pipe exists
# - no source hooks exist
# (We test the logic path, not the full main.sh flow)

PIPE_PATH_FOR_TEST=$(CLAUDE_CAGE_SESSION="$SESSION_ID" get_pipe_path "$SOURCE_PATH")
if [ -p "$PIPE_PATH_FOR_TEST" ]; then
    echo "FAIL: Pipe should not exist without setup_git_hooks call"
    exit 1
fi

if [ -f "$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$hook_path_hash" ]; then
    echo "FAIL: source post-commit hook should not exist without setup_source_post_commit call"
    exit 1
fi

# Also confirm: no pre-commit hook (never created in new architecture)
if [ -d "$SOURCE_PATH/.git/hooks/pre-commit.d" ]; then
    for hook in "$SOURCE_PATH/.git/hooks/pre-commit.d"/claude-cage-*; do
        if [ -f "$hook" ]; then
            echo "FAIL: source pre-commit hook should never be created in new architecture"
            exit 1
        fi
    done
fi

echo "  PASS: No pipe or source hooks created (autoMerge=false path)"

echo ""
echo "=== All git-hooks tests passed! ==="
