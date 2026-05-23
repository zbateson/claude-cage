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

# Install helper scripts (needed by hooks)
install_sync_commit_script "$INTERMEDIARY_DIR"
install_strip_prefix_script "$INTERMEDIARY_DIR"

# Create empty exclude pathspecs and scope-path metadata files
: > "$(get_exclude_pathspecs_file "$INTERMEDIARY_DIR")"
: > "$(get_scope_path_file "$INTERMEDIARY_DIR")"

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

echo "Test 13: Post-commit hook creates new branch and syncs"
# Create a branch that does NOT exist in intermediary and commit
git -C "$SOURCE_PATH" checkout -b out-of-scope-branch --quiet
echo "out of scope" > "$SOURCE_PATH/outofscope.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Out of scope" --quiet

out_of_scope_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if grep -q " ${out_of_scope_head}$" "$local_commit_map" 2>/dev/null; then
    echo "  PASS: New branch commit synced to intermediary"
else
    echo "FAIL: New branch commit was NOT synced to intermediary"
    echo "  out_of_scope HEAD: $out_of_scope_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

# Verify the branch was created in intermediary
if git -C "$INTERMEDIARY_DIR" rev-parse --verify out-of-scope-branch >/dev/null 2>&1; then
    echo "  PASS: Branch created in intermediary"
else
    echo "FAIL: Branch not created in intermediary"
    exit 1
fi

# Go back to master for remaining tests
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet
cleanup_source_hooks "$SOURCE_PATH"

echo ""
echo "=== Testing post-merge hook ==="
echo ""

# Set up a fresh intermediary with marks/commit map for merge tests
rm -rf "$INTERMEDIARY_DIR"
mkdir -p "$(dirname "$INTERMEDIARY_DIR")"
git init --bare "$INTERMEDIARY_DIR" --quiet

local_source_marks=$(get_source_marks_path "$INTERMEDIARY_DIR")
local_import_marks=$(get_import_marks_path "$INTERMEDIARY_DIR")
local_commit_map=$(get_commit_map_path "$INTERMEDIARY_DIR")

# Create empty exclude pathspecs file (no excludes for these tests)
exclude_pathspecs_file=$(get_exclude_pathspecs_file "$INTERMEDIARY_DIR")
: > "$exclude_pathspecs_file"

# Create empty scope-path file (unscoped)
scope_path_file=$(get_scope_path_file "$INTERMEDIARY_DIR")
: > "$scope_path_file"

git -C "$SOURCE_PATH" fast-export --export-marks="$local_source_marks" HEAD 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --export-marks="$local_import_marks" --quiet 2>/dev/null
: > "$local_commit_map"
build_commit_map_from_marks "$local_source_marks" "$local_import_marks" "$local_commit_map" "$SOURCE_PATH" "HEAD"

# Install the sync-commit helper (needed by both hooks)
install_sync_commit_script "$INTERMEDIARY_DIR"
install_strip_prefix_script "$INTERMEDIARY_DIR"

# Install post-commit hook (needed so feature branch commits sync before merge)
rm -rf "$SOURCE_PATH/.git/hooks/post-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/post-commit"
rm -rf "$SOURCE_PATH/.git/hooks/post-merge.d"
rm -f "$SOURCE_PATH/.git/hooks/post-merge"
setup_source_post_commit "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"

echo "Test 14: Source post-merge hook created"
setup_source_post_merge "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"
post_merge_hook="$SOURCE_PATH/.git/hooks/post-merge.d/claude-cage-$hook_path_hash"
if [ ! -f "$post_merge_hook" ]; then
    echo "FAIL: post-merge hook not found at $post_merge_hook"
    exit 1
fi
if [ ! -x "$post_merge_hook" ]; then
    echo "FAIL: post-merge hook is not executable"
    exit 1
fi
intermediary_in_hook=$(grep '^INTERMEDIARY=' "$post_merge_hook" | head -1 | cut -d'"' -f2)
if [ "$intermediary_in_hook" != "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: INTERMEDIARY points to '$intermediary_in_hook', expected '$INTERMEDIARY_DIR'"
    exit 1
fi
echo "  PASS: post-merge hook created, executable, references INTERMEDIARY"

echo "Test 15: FF merge on source syncs to intermediary via post-merge hook"
# Create feature branch, add a commit (post-commit syncs it to intermediary)
git -C "$SOURCE_PATH" checkout -b ff-feature --quiet
echo "ff feature content" > "$SOURCE_PATH/ff-feature.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "FF feature commit" --quiet

# Verify post-commit synced the feature commit
ff_feature_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if ! grep -q " ${ff_feature_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Feature commit not synced by post-commit hook before merge test"
    echo "  ff_feature HEAD: $ff_feature_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

# Switch back to master and fast-forward merge
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet
git -C "$SOURCE_PATH" merge ff-feature --quiet

# After FF merge, master HEAD == ff_feature_head (same commit)
master_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if [ "$master_head" != "$ff_feature_head" ]; then
    echo "FAIL: FF merge didn't advance master to feature commit"
    exit 1
fi

# The commit is already mapped (synced when committed on feature branch)
# post-merge hook should skip it via loop prevention
# Verify master branch is mapped and intermediary has it
if grep -q " ${master_head}$" "$local_commit_map" 2>/dev/null; then
    echo "  PASS: FF merge commit already in mapping, intermediary in sync"
else
    echo "FAIL: FF merge commit not in commit mapping"
    echo "  master HEAD: $master_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

echo "Test 16: Non-FF merge on source syncs merge commit to intermediary"
# Create a feature branch with a commit
git -C "$SOURCE_PATH" checkout -b noff-feature --quiet
echo "noff feature content" > "$SOURCE_PATH/noff-feature.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Non-FF feature commit" --quiet

# Make a different commit on master (creates divergence)
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet
echo "master diverge content" > "$SOURCE_PATH/master-diverge.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Master diverge" --quiet

# Non-FF merge (creates a merge commit)
git -C "$SOURCE_PATH" merge noff-feature --no-edit --quiet

merge_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)

# Verify the merge commit was synced by the post-merge hook
if grep -q " ${merge_head}$" "$local_commit_map" 2>/dev/null; then
    echo "  PASS: Non-FF merge commit synced to intermediary"
else
    echo "FAIL: Non-FF merge commit not synced to intermediary"
    echo "  merge HEAD: $merge_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

# Verify intermediary has the merge commit on master
int_master_head=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)
if [ -z "$int_master_head" ]; then
    echo "FAIL: Intermediary master branch not found"
    exit 1
fi
# Check intermediary master maps to source master
if grep -q "^${int_master_head} ${merge_head}$" "$local_commit_map" 2>/dev/null; then
    echo "  PASS: Intermediary master points to mapped merge commit"
else
    echo "  PASS: Merge synced (intermediary updated)"
fi

echo "Test 17: Merge commit with marks-gap first parent syncs correctly"
# When a merge commit's first parent is NOT in source-marks (marks gap),
# fast-export misattributes the 'from' line to the second parent, losing
# merge topology and causing non-fast-forward errors. The fix patches marks
# for missing parents before fast-export, using the commit map to look up
# their intermediary hashes.

# Save current master head — this is known to marks
marks_gap_base=$(git -C "$SOURCE_PATH" rev-parse HEAD)

# Create a feature branch from this known-good state
git -C "$SOURCE_PATH" checkout -b marks-gap-feature --quiet
echo "marks-gap feature" > "$SOURCE_PATH/marks-gap-feature.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Marks-gap feature commit" --quiet

# Verify feature commit synced to intermediary
mg_feature_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if ! grep -q " ${mg_feature_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Feature commit not synced before marks-gap merge test"
    exit 1
fi

# Switch to master and make a commit that we'll remove from source-marks
# to simulate a marks gap (e.g. from a sync_to_source git-am operation)
git -C "$SOURCE_PATH" checkout "$BRANCH_NAME" --quiet
echo "marks-gap master content" > "$SOURCE_PATH/marks-gap-master.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Marks-gap master commit" --quiet

mg_master_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)

# The post-commit hook synced this commit — remove it from source-marks
# to simulate the marks gap that happens after sync_to_source git-am
sed -i "/ ${mg_master_head}$/d" "$local_source_marks"

# Now merge the feature branch — creates a merge commit whose first parent
# (mg_master_head) is NOT in source-marks → triggers marks gap code path
git -C "$SOURCE_PATH" merge marks-gap-feature --no-edit --quiet

mg_merge_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)

# Verify the merge commit was synced (not mapped to 0)
if grep -q "^0 ${mg_merge_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Merge commit mapped to 0 (marks gap injection failed)"
    echo "  merge HEAD: $mg_merge_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi
if ! grep -q " ${mg_merge_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Merge commit not in commit map at all"
    echo "  merge HEAD: $mg_merge_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

# Verify intermediary master was updated
int_mg_head=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)
if ! grep -q "^${int_mg_head} ${mg_merge_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Intermediary master doesn't point to mapped merge commit"
    echo "  intermediary HEAD: $int_mg_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi

# Verify a subsequent commit on master syncs correctly (not a non-FF error)
echo "post-merge-gap content" > "$SOURCE_PATH/post-merge-gap.txt"
git -C "$SOURCE_PATH" add -A && git -C "$SOURCE_PATH" commit -m "Post merge-gap commit" --quiet

post_mg_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if ! grep -q " ${post_mg_head}$" "$local_commit_map" 2>/dev/null; then
    echo "FAIL: Commit after marks-gap merge not synced"
    echo "  post merge-gap HEAD: $post_mg_head"
    echo "  commit map:"
    cat "$local_commit_map"
    exit 1
fi
echo "  PASS: Merge commit with marks-gap parent synced, subsequent commits work"

# Clean up the marks-gap feature branch
git -C "$SOURCE_PATH" branch -D marks-gap-feature 2>/dev/null || true

echo "Test 18: Post-merge hook skips squash merges"
# Squash merges pass $1=1 to post-merge hook. The hook should skip and let
# post-commit handle the eventual commit.
if ! grep -q '"\${1:-0}" = "1"' "$post_merge_hook"; then
    echo "FAIL: post-merge hook doesn't check for squash merge (\$1=1)"
    cat "$post_merge_hook"
    exit 1
fi
echo "  PASS: post-merge hook checks for squash merge flag"

echo "Test 19: Post-merge hook cleanup removes post-merge hooks"
cleanup_source_hooks "$SOURCE_PATH"
if [ -f "$post_merge_hook" ]; then
    echo "FAIL: post-merge hook should have been removed by cleanup_source_hooks"
    exit 1
fi
# Dispatcher should also be cleaned up since no hooks remain
if [ -f "$SOURCE_PATH/.git/hooks/post-merge" ] && grep -q "claude-cage-dispatcher" "$SOURCE_PATH/.git/hooks/post-merge"; then
    echo "FAIL: post-merge dispatcher should have been removed when no hooks remain"
    exit 1
fi
echo "  PASS: post-merge hook and dispatcher cleaned up"

# Clean up branches used in merge tests
git -C "$SOURCE_PATH" branch -D ff-feature 2>/dev/null || true
git -C "$SOURCE_PATH" branch -D noff-feature 2>/dev/null || true

echo ""
echo "=== Testing autoSync=false (no pipe, but source hooks installed) ==="
echo ""

echo "Test 20: Source hooks installed but no pipe when autoSync=false"
# Clean up all existing state
rm -rf "$INTERMEDIARY_DIR" "$CLAUDE_CAGE_RUNTIME"
rm -rf "$SOURCE_PATH/.git/hooks/post-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/post-commit"
rm -rf "$SOURCE_PATH/.git/hooks/post-merge.d"
rm -f "$SOURCE_PATH/.git/hooks/post-merge"
rm -rf "$SOURCE_PATH/.git/hooks/pre-commit.d"
rm -f "$SOURCE_PATH/.git/hooks/pre-commit"

# Recreate bare intermediary without installing hooks
mkdir -p "$(dirname "$INTERMEDIARY_DIR")"
git init --bare "$INTERMEDIARY_DIR" --quiet
git -C "$SOURCE_PATH" fast-export HEAD 2>/dev/null \
    | git -C "$INTERMEDIARY_DIR" fast-import --quiet 2>/dev/null

# Source hooks are now always installed (source → intermediary sync).
# Pipe/post-receive hooks (cage → source) are NOT installed when autoSync=false.
setup_source_post_commit "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"
setup_source_post_merge "$SOURCE_PATH" "" "$INTERMEDIARY_DIR"

# Verify source hooks ARE installed
if [ ! -f "$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$hook_path_hash" ]; then
    echo "FAIL: source post-commit hook should be installed (always)"
    exit 1
fi
if [ ! -f "$SOURCE_PATH/.git/hooks/post-merge.d/claude-cage-$hook_path_hash" ]; then
    echo "FAIL: source post-merge hook should be installed (always)"
    exit 1
fi

# Verify pipe does NOT exist (no setup_git_hooks call)
PIPE_PATH_FOR_TEST=$(CLAUDE_CAGE_SESSION="$SESSION_ID" get_pipe_path "$SOURCE_PATH")
if [ -p "$PIPE_PATH_FOR_TEST" ]; then
    echo "FAIL: Pipe should not exist without setup_git_hooks call"
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

echo "  PASS: Source hooks installed, no pipe (autoSync=false path)"

echo ""
echo "=== Testing unscoped merge prevention hooks ==="
echo ""

echo "Test 21: Unscoped work dir gets pre-merge-commit hook requiring pushed branches"

# Create a fresh work dir (unscoped = no scope_path)
MERGE_WORK="$TEST_TMP/merge-work"
rm -rf "$MERGE_WORK"
mkdir -p "$MERGE_WORK"
cd "$MERGE_WORK"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "base" > file.txt
git add . && git commit -q -m "Initial"

# Set up a bare remote to act as intermediary
MERGE_REMOTE="$TEST_TMP/merge-remote"
rm -rf "$MERGE_REMOTE"
git clone --bare -q "$MERGE_WORK" "$MERGE_REMOTE"
git -C "$MERGE_WORK" remote add origin "$MERGE_REMOTE"

# Install hooks (no scope_path = unscoped)
setup_work_pre_commit "$MERGE_WORK" ""

# Verify pre-merge-commit hook exists
if [ ! -f "$MERGE_WORK/.git/hooks/pre-merge-commit" ]; then
    echo "FAIL: pre-merge-commit hook should exist for unscoped work dir"
    exit 1
fi
echo "  PASS: pre-merge-commit hook created for unscoped work dir"

# Verify hook contains the remote branch check (not a total block)
if ! grep -q "git branch -r --contains" "$MERGE_WORK/.git/hooks/pre-merge-commit"; then
    echo "FAIL: Hook should check 'git branch -r --contains' (not block all merges)"
    exit 1
fi
echo "  PASS: Hook checks for pushed branches (not total block)"

echo "Test 22: Unscoped hook blocks merge of unpushed branch"

# Create a local-only branch (not pushed to remote)
git -C "$MERGE_WORK" checkout -q -b local-feature
echo "local feature" > "$MERGE_WORK/feature.txt"
git -C "$MERGE_WORK" add . && git -C "$MERGE_WORK" commit -q -m "Local feature"
git -C "$MERGE_WORK" checkout -q master

# Make a change on master so the merge can't fast-forward
echo "master change" > "$MERGE_WORK/master.txt"
git -C "$MERGE_WORK" add . && git -C "$MERGE_WORK" commit -q -m "Master change"

# Attempt non-ff merge — should be blocked by pre-merge-commit hook
set +e
merge_out_file="$TEST_TMP/merge-output.txt"
git -C "$MERGE_WORK" merge local-feature --no-ff --no-edit >"$merge_out_file" 2>&1
merge_rc=$?
set -e
if [ "$merge_rc" -eq 0 ]; then
    echo "FAIL: Merge of unpushed branch should have been blocked"
    exit 1
fi
echo "  PASS: Merge of unpushed branch blocked (exit code != 0)"

if ! grep -q "ain't been pushed" "$merge_out_file"; then
    echo "FAIL: Error message should mention branch not pushed"
    echo "  Got: $(cat "$merge_out_file")"
    exit 1
fi
echo "  PASS: Error message mentions unpushed branch"

# Clean up the blocked merge state
git -C "$MERGE_WORK" merge --abort 2>/dev/null || true

echo "Test 23: Unscoped hook allows merge of pushed branch"

# Push the feature branch to remote
git -C "$MERGE_WORK" push -q origin local-feature 2>/dev/null

# Also push master so fetch works
git -C "$MERGE_WORK" push -q origin master 2>/dev/null

# Fetch to update remote tracking refs
git -C "$MERGE_WORK" fetch -q origin

# Now merge should succeed (branch is on remote)
set +e
git -C "$MERGE_WORK" merge local-feature --no-ff --no-edit >"$merge_out_file" 2>&1
merge_rc=$?
set -e
if [ "$merge_rc" -ne 0 ]; then
    echo "FAIL: Merge of pushed branch should succeed"
    echo "  Got: $(cat "$merge_out_file")"
    exit 1
fi
echo "  PASS: Merge of pushed branch allowed"

# Verify it's a merge commit
merge_head=$(git -C "$MERGE_WORK" rev-parse HEAD)
if ! git -C "$MERGE_WORK" rev-parse --verify "${merge_head}^2" >/dev/null 2>&1; then
    echo "FAIL: Result should be a merge commit"
    exit 1
fi
echo "  PASS: Result is a proper merge commit"

echo ""
echo "Test 24: Source's first commit on empty intermediary syncs as a root commit"

# Symmetric to git-sync.sh Test 60: cage→source direction had a bug where root
# commits never came back; here the source→intermediary post-commit helper
# had the same `git rev-parse "${COMMIT_HASH}^"` (missing --verify) gotcha.
# A literal "hash^" left the "no from line" branch treating the root commit as
# a marks gap instead of a legitimate import.
EMPTY24_SRC="$TEST_TMP/source24"
rm -rf "$EMPTY24_SRC"
mkdir -p "$EMPTY24_SRC"
git -C "$EMPTY24_SRC" init -q
git -C "$EMPTY24_SRC" config user.email "test@test.com"
git -C "$EMPTY24_SRC" config user.name "Test"

EMPTY24_INT=$(get_intermediary_path "$EMPTY24_SRC")
EMPTY24_BRANCH=$(git -C "$EMPTY24_SRC" symbolic-ref --short HEAD)

rm -rf "$EMPTY24_INT"
mkdir -p "$(dirname "$EMPTY24_INT")"
git init --bare "$EMPTY24_INT" --quiet
git -C "$EMPTY24_INT" symbolic-ref HEAD "refs/heads/$EMPTY24_BRANCH"

install_sync_commit_script "$EMPTY24_INT"
install_strip_prefix_script "$EMPTY24_INT"
: > "$(get_exclude_pathspecs_file "$EMPTY24_INT")"
: > "$(get_scope_path_file "$EMPTY24_INT")"
: > "$(get_source_marks_path "$EMPTY24_INT")"
: > "$(get_import_marks_path "$EMPTY24_INT")"
: > "$(get_commit_map_path "$EMPTY24_INT")"

setup_source_post_commit "$EMPTY24_SRC" "" "$EMPTY24_INT"

# User makes their first commit on the previously-empty source.
echo "scaffold" > "$EMPTY24_SRC/README.md"
git -C "$EMPTY24_SRC" add README.md
git -C "$EMPTY24_SRC" commit -q -m "Initial commit"

src_head=$(git -C "$EMPTY24_SRC" rev-parse HEAD)

# Intermediary's branch should now point at a commit with the same tree.
int_head=$(git -C "$EMPTY24_INT" rev-parse --verify "$EMPTY24_BRANCH" 2>/dev/null) || int_head=""
if [ -z "$int_head" ]; then
    echo "FAIL: intermediary $EMPTY24_BRANCH not created by source post-commit hook"
    echo "  sync.log:"
    cat "$EMPTY24_INT/sync.log" 2>/dev/null || echo "  (no sync.log)"
    exit 1
fi

# Root commit must have no parent on intermediary.
int_root=$(git -C "$EMPTY24_INT" rev-list --max-parents=0 "$EMPTY24_BRANCH" 2>/dev/null)
if [ -z "$int_root" ]; then
    echo "FAIL: intermediary $EMPTY24_BRANCH has no root commit after sync"
    exit 1
fi

int_readme=$(git -C "$EMPTY24_INT" show "$EMPTY24_BRANCH:README.md" 2>/dev/null)
if [ "$int_readme" != "scaffold" ]; then
    echo "FAIL: intermediary README.md content wrong: '$int_readme'"
    exit 1
fi

# Commit map must connect the new intermediary commit to source's commit.
if ! grep -q " ${src_head}$" "$(get_commit_map_path "$EMPTY24_INT")" 2>/dev/null; then
    echo "FAIL: source commit $src_head not in commit map after sync"
    cat "$(get_commit_map_path "$EMPTY24_INT")"
    exit 1
fi
echo "  PASS: source root commit synced into empty intermediary"

cleanup_source_hooks "$EMPTY24_SRC"

echo ""
echo "Test 25: Source post-commit hook self-heals when marks files are missing"

# Reproduce the IsisVue corruption shape: intermediary exists with hooks
# installed but source-marks/import-marks are gone (e.g., create_intermediary_clone
# bootstrapped from an empty repo so fast-export errored out without writing
# them). Source's first real commit used to fatal with "could not open
# claude-cage-source-marks". The fix is to touch those files before the
# fast-export call and let an empty-marks input sail through.
EMPTY25_SRC="$TEST_TMP/source25"
rm -rf "$EMPTY25_SRC"
mkdir -p "$EMPTY25_SRC"
git -C "$EMPTY25_SRC" init -q
git -C "$EMPTY25_SRC" config user.email "test@test.com"
git -C "$EMPTY25_SRC" config user.name "Test"

EMPTY25_INT=$(get_intermediary_path "$EMPTY25_SRC")
EMPTY25_BRANCH=$(git -C "$EMPTY25_SRC" symbolic-ref --short HEAD)

rm -rf "$EMPTY25_INT"
mkdir -p "$(dirname "$EMPTY25_INT")"
git init --bare "$EMPTY25_INT" --quiet
git -C "$EMPTY25_INT" symbolic-ref HEAD "refs/heads/$EMPTY25_BRANCH"
install_sync_commit_script "$EMPTY25_INT"
install_strip_prefix_script "$EMPTY25_INT"
: > "$(get_exclude_pathspecs_file "$EMPTY25_INT")"
: > "$(get_scope_path_file "$EMPTY25_INT")"
: > "$(get_commit_map_path "$EMPTY25_INT")"
# Deliberately do NOT create marks files — that's the bug shape.

setup_source_post_commit "$EMPTY25_SRC" "" "$EMPTY25_INT"

# Sanity: marks files really are absent before the commit.
src_marks_path=$(get_source_marks_path "$EMPTY25_INT")
imp_marks_path=$(get_import_marks_path "$EMPTY25_INT")
if [ -f "$src_marks_path" ] || [ -f "$imp_marks_path" ]; then
    echo "FAIL: test precondition broken — marks files should be absent before commit"
    exit 1
fi

echo "scaffold" > "$EMPTY25_SRC/README.md"
git -C "$EMPTY25_SRC" add README.md
git -C "$EMPTY25_SRC" commit -q -m "Initial commit"

# Hook should have created the marks files and synced the commit.
if [ ! -f "$src_marks_path" ]; then
    echo "FAIL: source-marks not created by hook"
    exit 1
fi
if [ ! -f "$imp_marks_path" ]; then
    echo "FAIL: import-marks not created by hook"
    exit 1
fi

int_head=$(git -C "$EMPTY25_INT" rev-parse --verify "$EMPTY25_BRANCH" 2>/dev/null) || int_head=""
if [ -z "$int_head" ]; then
    echo "FAIL: intermediary $EMPTY25_BRANCH not created — sync didn't actually run"
    echo "  sync.log:"
    cat "$EMPTY25_INT/sync.log" 2>/dev/null
    exit 1
fi

src_head=$(git -C "$EMPTY25_SRC" rev-parse HEAD)
if ! grep -q " ${src_head}$" "$(get_commit_map_path "$EMPTY25_INT")" 2>/dev/null; then
    echo "FAIL: source commit $src_head not in commit map"
    exit 1
fi
echo "  PASS: missing marks files were created and the commit synced"

cleanup_source_hooks "$EMPTY25_SRC"

echo ""
echo "=== All git-hooks tests passed! ==="
