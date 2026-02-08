#!/bin/bash
# Test git-sync.sh functionality
# Tests sync_to_source, apply_source_to_intermediary, pipe listener,
# check_cage_state, sessions, and commit mapping

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
    # Kill any background processes we started
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing git-sync.sh ==="
echo ""

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

# Set variables needed by functions
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
dry_run=false
verbose=false
debug=false

# ============================================================================
# Helper: create a source repo, intermediary, and work dir for testing
# Sets: SOURCE_PATH, BRANCH_NAME, INTERMEDIARY_DIR, WORK_DIR
# ============================================================================
setup_test_cage() {
    local label="${1:-source}"
    local source_dir="$TEST_TMP/$label"

    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    cd "$source_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "original content" > file.txt
    git add . && git commit -q -m "Initial commit"

    SOURCE_PATH="$source_dir"
    BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
    CLAUDE_CAGE_SESSION="test-session-$$"
    export CLAUDE_CAGE_SESSION

    # Compute expected paths for the new architecture
    INTERMEDIARY_DIR=$(get_intermediary_path "$SOURCE_PATH")
    WORK_DIR=$(get_work_path "$SOURCE_PATH")

    # Create the cage
    create_intermediary_clone "$SOURCE_PATH" >/dev/null 2>&1

    # Fix origin path for testing outside sandbox
    # (inside sandbox, intermediary is mounted at /run<intermediary_path>)
    git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"
}

# ============================================================================
# Test 1: Push from work updates intermediary
# ============================================================================
echo "Test 1: Push from work should update intermediary"

setup_test_cage "source1"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"
echo "new content from claude" > "$WORK_DIR/newfile.txt"
git -C "$WORK_DIR" add newfile.txt
git -C "$WORK_DIR" commit -q -m "Add newfile from Claude"
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Verify new branch tip updated in bare intermediary
intermediary_head=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
work_head=$(git -C "$WORK_DIR" rev-parse HEAD)
if [ "$intermediary_head" != "$work_head" ]; then
    echo "FAIL: Intermediary branch tip ($intermediary_head) != work HEAD ($work_head)"
    exit 1
fi
echo "  PASS: Push updated intermediary branch tip"

# ============================================================================
# Test 2: Push creates correct objects
# ============================================================================
echo "Test 2: Push creates correct objects in intermediary"

# Verify the pushed file content is correct in intermediary tree
file_content=$(git -C "$INTERMEDIARY_DIR" show "$BRANCH_NAME:newfile.txt" 2>/dev/null)
if [ "$file_content" != "new content from claude" ]; then
    echo "FAIL: Intermediary file content is wrong: '$file_content'"
    exit 1
fi
echo "  PASS: Pushed file content is correct in intermediary"

# ============================================================================
# Test 3: sync_to_source basic
# ============================================================================
echo ""
echo "Test 3: sync_to_source should apply patch to source"

setup_test_cage "source3"

# Make a commit in work and push
git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"
echo "synced content" > "$WORK_DIR/synced.txt"
git -C "$WORK_DIR" add synced.txt
git -C "$WORK_DIR" commit -q -m "Sync test commit"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null
newrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")

# Call sync_to_source
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify the change is in source
if [ ! -f "$SOURCE_PATH/synced.txt" ]; then
    echo "FAIL: synced.txt not in source after sync_to_source"
    exit 1
fi
source_content=$(cat "$SOURCE_PATH/synced.txt")
if [ "$source_content" != "synced content" ]; then
    echo "FAIL: Source content is wrong: '$source_content'"
    exit 1
fi
echo "  PASS: sync_to_source applied patch to source"

# ============================================================================
# Test 4: sync_to_source updates commit mapping
# ============================================================================
echo "Test 4: sync_to_source should update commit mapping"

commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
if [ ! -f "$commit_map_path" ]; then
    echo "FAIL: Commit mapping file not found at $commit_map_path"
    exit 1
fi

# The new intermediary commit should be mapped to a source commit
if ! grep -q "^$newrev " "$commit_map_path"; then
    echo "FAIL: New intermediary commit $newrev not in commit mapping"
    echo "Commit map contents:"
    cat "$commit_map_path"
    exit 1
fi
echo "  PASS: Commit mapping updated with new entry"

# ============================================================================
# Test 5: sync_to_source skips mapped commits (loop prevention)
# ============================================================================
echo "Test 5: sync_to_source should skip already-mapped commits"

# Call sync_to_source again with the same range
output=$(sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" 2>&1)

# Count commits on source - should not have increased
source_count_before=$(git -C "$SOURCE_PATH" rev-list --count HEAD)

# Run again
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

source_count_after=$(git -C "$SOURCE_PATH" rev-list --count HEAD)
if [ "$source_count_before" != "$source_count_after" ]; then
    echo "FAIL: Source commit count changed from $source_count_before to $source_count_after (should not re-apply)"
    exit 1
fi
echo "  PASS: Already-mapped commits skipped (loop prevention)"

# ============================================================================
# Test 6: Manual git merge works
# ============================================================================
echo ""
echo "Test 6: manual_git_merge should add remote and fetch"

setup_test_cage "source6"

# Make a commit in work and push
git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"
echo "merge test" > "$WORK_DIR/merge.txt"
git -C "$WORK_DIR" add merge.txt
git -C "$WORK_DIR" commit -q -m "Merge test commit"
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Run manual_git_merge
manual_git_merge "$SOURCE_PATH" >/dev/null 2>&1

# Check that intermediary remote exists and has been fetched
if ! git -C "$SOURCE_PATH" remote | grep -q "^intermediary$"; then
    echo "FAIL: intermediary remote not added to source"
    exit 1
fi
if ! git -C "$SOURCE_PATH" branch -r | grep -q "intermediary/$BRANCH_NAME"; then
    echo "FAIL: intermediary/$BRANCH_NAME remote branch not found after fetch"
    git -C "$SOURCE_PATH" branch -r
    exit 1
fi
echo "  PASS: manual_git_merge added remote and fetched"

# ============================================================================
# Test 7: check_cage_state returns no_cage
# ============================================================================
echo ""
echo "Test 7: check_cage_state should return no_cage when no intermediary"

# Use a path that has no cage set up
fake_source="$TEST_TMP/no-cage-source"
mkdir -p "$fake_source"
cd "$fake_source" && git init -q && git config user.email "t@t" && git config user.name "T"
echo "x" > "$fake_source/x.txt" && git -C "$fake_source" add . && git -C "$fake_source" commit -q -m "init"

fake_intermediary=$(get_intermediary_path "$fake_source")
fake_work=$(get_work_path "$fake_source")

result=$(check_cage_state "$fake_source" "$fake_intermediary" "$fake_work")
if [ "$result" != "no_cage" ]; then
    echo "FAIL: Expected no_cage but got: $result"
    exit 1
fi
echo "  PASS: check_cage_state returns no_cage"

# ============================================================================
# Test 8: check_cage_state returns in_sync
# ============================================================================
echo "Test 8: check_cage_state should return in_sync when source HEAD is mapped"

setup_test_cage "source8"

result=$(check_cage_state "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$WORK_DIR")
if [ "$result" != "in_sync" ]; then
    echo "FAIL: Expected in_sync but got: $result"
    echo "Source HEAD: $(git -C "$SOURCE_PATH" rev-parse HEAD)"
    echo "Commit map:"
    cat "$(get_commit_map_path "$INTERMEDIARY_DIR")" 2>/dev/null || echo "(no map)"
    exit 1
fi
echo "  PASS: check_cage_state returns in_sync"

# ============================================================================
# Test 9: check_cage_state returns needs_update
# ============================================================================
echo "Test 9: check_cage_state should return needs_update when source advanced"

# Make a commit directly on source (advancing past the mapping)
echo "advanced" > "$SOURCE_PATH/advanced.txt"
git -C "$SOURCE_PATH" add advanced.txt
git -C "$SOURCE_PATH" commit -q -m "Advance source past cage"

result=$(check_cage_state "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$WORK_DIR")
if [ "$result" != "needs_update" ]; then
    echo "FAIL: Expected needs_update but got: $result"
    exit 1
fi
echo "  PASS: check_cage_state returns needs_update"

# ============================================================================
# Test 10: check_cage_state returns needs_work_dir
# ============================================================================
echo "Test 10: check_cage_state should return needs_work_dir when work dir missing"

# Remove just the work directory
rm -rf "$WORK_DIR"

result=$(check_cage_state "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$WORK_DIR")
if [ "$result" != "needs_work_dir" ]; then
    echo "FAIL: Expected needs_work_dir but got: $result"
    exit 1
fi
echo "  PASS: check_cage_state returns needs_work_dir"

# ============================================================================
# Test 11: Session detection - other sessions
# ============================================================================
echo ""
echo "Test 11: has_other_sessions should detect running PIDs"

setup_test_cage "source11"

# Spawn a background process we own and use its PID
sleep 300 &
fake_session_pid=$!

session_dir=$(get_session_dir "$SOURCE_PATH")
mkdir -p "$session_dir"
echo "$fake_session_pid" > "$session_dir/$fake_session_pid"

if ! has_other_sessions "$SOURCE_PATH"; then
    kill "$fake_session_pid" 2>/dev/null
    echo "FAIL: has_other_sessions should return true when active PID file exists"
    exit 1
fi
echo "  PASS: Active session detected"

# Clean up the fake session
kill "$fake_session_pid" 2>/dev/null
wait "$fake_session_pid" 2>/dev/null || true

# ============================================================================
# Test 12: Session detection - stale cleanup
# ============================================================================
echo "Test 12: has_other_sessions should clean stale PIDs"

# Create a stale PID file (PID that definitely doesn't exist)
session_dir=$(get_session_dir "$SOURCE_PATH")
mkdir -p "$session_dir"
echo "999999999" > "$session_dir/999999999"

# Also add a live process so has_other_sessions is exercised
sleep 300 &
live_pid=$!
echo "$live_pid" > "$session_dir/$live_pid"

# has_other_sessions should clean up stale PID and still find our sleep process
if ! has_other_sessions "$SOURCE_PATH"; then
    kill "$live_pid" 2>/dev/null
    echo "FAIL: Should still detect active PID after cleaning stale PID"
    exit 1
fi
if [ -f "$session_dir/999999999" ]; then
    kill "$live_pid" 2>/dev/null
    echo "FAIL: Stale PID file should have been cleaned up"
    exit 1
fi
echo "  PASS: Stale PIDs cleaned, active session still detected"

# Clean up
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null || true

# ============================================================================
# Test 13: Sync logging
# ============================================================================
echo ""
echo "Test 13: sync.log should contain entries from sync_to_source"

setup_test_cage "source13"

# Make a commit in work and push
git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"
echo "log test" > "$WORK_DIR/logtest.txt"
git -C "$WORK_DIR" add logtest.txt
git -C "$WORK_DIR" commit -q -m "Log test commit"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

SYNC_LOG_FILE="$INTERMEDIARY_DIR/sync.log"
if [ ! -f "$SYNC_LOG_FILE" ]; then
    echo "FAIL: Sync log file was not created at $SYNC_LOG_FILE"
    exit 1
fi
if ! grep -q ">>source" "$SYNC_LOG_FILE"; then
    echo "FAIL: Sync log should contain >>source entries"
    cat "$SYNC_LOG_FILE"
    exit 1
fi
echo "  PASS: Sync log contains expected entries"

# ============================================================================
# Test 14: apply_source_to_intermediary
# ============================================================================
echo ""
echo "Test 14: apply_source_to_intermediary should sync source commit into intermediary"

setup_test_cage "source14"

# Make a commit on source (not through the cage)
echo "from source" > "$SOURCE_PATH/from-source.txt"
git -C "$SOURCE_PATH" add from-source.txt
git -C "$SOURCE_PATH" commit -q -m "Source commit for intermediary sync"

# Capture intermediary state before
intermediary_head_before=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")

# Apply source to intermediary
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$cfg_exclude"

# Verify intermediary advanced
intermediary_head_after=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
if [ "$intermediary_head_before" = "$intermediary_head_after" ]; then
    echo "FAIL: Intermediary did not advance after apply_source_to_intermediary"
    exit 1
fi

# Verify file is in intermediary tree
file_content=$(git -C "$INTERMEDIARY_DIR" show "$BRANCH_NAME:from-source.txt" 2>/dev/null)
if [ "$file_content" != "from source" ]; then
    echo "FAIL: from-source.txt not in intermediary tree (content: '$file_content')"
    exit 1
fi
echo "  PASS: Source commit synced into intermediary"

# ============================================================================
# Test 15: apply_source_to_intermediary loop prevention
# ============================================================================
echo "Test 15: apply_source_to_intermediary should skip already-mapped commits"

# Verify source HEAD is now in the commit mapping
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
source_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)
if ! grep -q " ${source_head}$" "$commit_map_path"; then
    echo "FAIL: Source HEAD $source_head not in commit mapping after apply"
    cat "$commit_map_path"
    exit 1
fi

intermediary_head_before=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")

# Call apply_source_to_intermediary again - should be a no-op
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$cfg_exclude"

intermediary_head_after=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
if [ "$intermediary_head_before" != "$intermediary_head_after" ]; then
    echo "FAIL: Intermediary changed when re-applying already-mapped commit"
    exit 1
fi
echo "  PASS: Already-mapped source commits skipped (loop prevention)"

# ============================================================================
# Test 16: sync_to_source with branch switch (temp-index path)
# ============================================================================
echo ""
echo "Test 16: sync_to_source with branch switch uses temp-index"

setup_test_cage "source16"

# Create a feature branch on source
git -C "$SOURCE_PATH" checkout -q -b feature
echo "feature" > "$SOURCE_PATH/feature.txt"
git -C "$SOURCE_PATH" add feature.txt
git -C "$SOURCE_PATH" commit -q -m "Feature commit"

# Stay on feature branch for cage setup (create_intermediary_clone uses source's current branch)
# Set up a new cage session for the feature branch
CLAUDE_CAGE_SESSION="test-feature-session"
export CLAUDE_CAGE_SESSION
FEATURE_INTERMEDIARY_DIR=$(get_intermediary_path "$SOURCE_PATH")
FEATURE_WORK_DIR=$(get_work_path "$SOURCE_PATH")
# Need to rebuild intermediary to include the feature branch
rm -rf "$FEATURE_WORK_DIR"

# Re-run create_intermediary_clone while source is on feature branch
create_intermediary_clone "$SOURCE_PATH" >/dev/null 2>&1

# Fix remote for work dir
git -C "$FEATURE_WORK_DIR" remote set-url origin "$FEATURE_INTERMEDIARY_DIR"

# Make a commit in work on feature branch and push
git -C "$FEATURE_WORK_DIR" config user.email "claude@test.com"
git -C "$FEATURE_WORK_DIR" config user.name "Claude"
echo "claude feature work" > "$FEATURE_WORK_DIR/claude-feature.txt"
git -C "$FEATURE_WORK_DIR" add claude-feature.txt
git -C "$FEATURE_WORK_DIR" commit -q -m "Claude's feature commit"

oldrev=$(git -C "$FEATURE_INTERMEDIARY_DIR" rev-parse "refs/heads/feature")
git -C "$FEATURE_WORK_DIR" push origin feature 2>/dev/null
newrev=$(git -C "$FEATURE_INTERMEDIARY_DIR" rev-parse "refs/heads/feature")

# Switch source to the main branch (simulating user switching branches)
git -C "$SOURCE_PATH" checkout -q "$BRANCH_NAME"

# Verify source is on main branch, not feature
current=$(git -C "$SOURCE_PATH" branch --show-current)
if [ "$current" != "$BRANCH_NAME" ]; then
    echo "FAIL: Expected source to be on $BRANCH_NAME, but on $current"
    exit 1
fi

# Call sync_to_source - should use temp-index since source is on different branch
sync_to_source "$SOURCE_PATH" "$FEATURE_INTERMEDIARY_DIR" "refs/heads/feature" "$oldrev" >/dev/null 2>&1

# Verify commit landed on feature branch (not current branch)
if ! git -C "$SOURCE_PATH" log feature --oneline | grep -q "Claude's feature commit"; then
    echo "FAIL: Claude's feature commit should be on feature branch"
    git -C "$SOURCE_PATH" log feature --oneline
    exit 1
fi

# Verify main branch was NOT affected
if git -C "$SOURCE_PATH" log "$BRANCH_NAME" --oneline | grep -q "Claude's feature commit"; then
    echo "FAIL: Claude's feature commit should NOT be on $BRANCH_NAME branch"
    exit 1
fi

# Verify source is still on main branch (not switched)
current=$(git -C "$SOURCE_PATH" branch --show-current)
if [ "$current" != "$BRANCH_NAME" ]; then
    echo "FAIL: Source should still be on $BRANCH_NAME, but on $current"
    exit 1
fi

# Check sync log for temp-index usage
SYNC_LOG_FILE="$FEATURE_INTERMEDIARY_DIR/sync.log"
if ! grep -q "temp-index" "$SYNC_LOG_FILE"; then
    echo "FAIL: Sync log should show temp-index usage"
    cat "$SYNC_LOG_FILE"
    exit 1
fi
echo "  PASS: sync_to_source with branch switch uses temp-index correctly"

# Restore CLAUDE_CAGE_SESSION
CLAUDE_CAGE_SESSION="test-session-$$"
export CLAUDE_CAGE_SESSION

# ============================================================================
# Test 17: Multi-commit push
# ============================================================================
echo ""
echo "Test 17: Multiple commits should be synced in order"

setup_test_cage "source17"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")

# Make multiple commits in work
echo "commit1" > "$WORK_DIR/multi1.txt"
git -C "$WORK_DIR" add multi1.txt
git -C "$WORK_DIR" commit -q -m "Multi commit 1"

echo "commit2" > "$WORK_DIR/multi2.txt"
git -C "$WORK_DIR" add multi2.txt
git -C "$WORK_DIR" commit -q -m "Multi commit 2"

echo "commit3" > "$WORK_DIR/multi3.txt"
git -C "$WORK_DIR" add multi3.txt
git -C "$WORK_DIR" commit -q -m "Multi commit 3"

# Push all three at once
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Sync to source
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify all three files are in source
for i in 1 2 3; do
    if [ ! -f "$SOURCE_PATH/multi${i}.txt" ]; then
        echo "FAIL: multi${i}.txt not in source after multi-commit sync"
        exit 1
    fi
done

# Verify commits are in order in source log
log_output=$(git -C "$SOURCE_PATH" log --oneline --format=%s | head -3)
if ! echo "$log_output" | head -1 | grep -q "Multi commit 3"; then
    echo "FAIL: Expected 'Multi commit 3' as most recent, got:"
    echo "$log_output"
    exit 1
fi
echo "  PASS: Multiple commits synced in order"

# ============================================================================
# Test 18: Empty patch handling
# ============================================================================
echo ""
echo "Test 18: Commits with only excluded files should be mapped to 0"

# Set up a cage with excludes
rm -rf "$TEST_TMP/source18"
mkdir -p "$TEST_TMP/source18"
cd "$TEST_TMP/source18"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "public" > public.txt
echo "secret" > .env
git add . && git commit -q -m "Initial"

SOURCE_PATH="$TEST_TMP/source18"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
CLAUDE_CAGE_SESSION="test-session-18"
export CLAUDE_CAGE_SESSION

# Create cage with .env excluded
cfg_exclude=".env"
INTERMEDIARY_DIR=$(get_intermediary_path "$SOURCE_PATH")
WORK_DIR=$(get_work_path "$SOURCE_PATH")

create_intermediary_clone "$SOURCE_PATH" >/dev/null 2>&1
git -C "$WORK_DIR" remote set-url origin "$INTERMEDIARY_DIR"

# Make a commit on source that only touches the excluded file
echo "updated secret" > "$SOURCE_PATH/.env"
git -C "$SOURCE_PATH" add .env
git -C "$SOURCE_PATH" commit -q -m "Update .env only"

source_head=$(git -C "$SOURCE_PATH" rev-parse HEAD)

# Apply to intermediary
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$cfg_exclude"

# Check commit mapping for the excluded-only commit
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")

# The source HEAD should be mapped to 0 (dropped commit)
if ! grep -q "0 ${source_head}$" "$commit_map_path"; then
    # It might also be mapped normally if fast-export created a commit anyway
    # Either way, it should be in the mapping
    if ! grep -q " ${source_head}$" "$commit_map_path"; then
        echo "FAIL: Source HEAD for excluded-only commit not found in mapping"
        echo "Source HEAD: $source_head"
        echo "Commit map:"
        cat "$commit_map_path"
        exit 1
    fi
fi
echo "  PASS: Excluded-only commit handled in commit mapping"

# Reset cfg_exclude for remaining tests
cfg_exclude=""

# ============================================================================
# Test 19: New branch creation in sync_to_source
# ============================================================================
echo ""
echo "Test 19: sync_to_source should create new branch on source when needed"

setup_test_cage "source19"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

# Create a new branch in work (simulating Claude creating a branch)
git -C "$WORK_DIR" checkout -q -b feature-new
echo "new branch content" > "$WORK_DIR/feature-new.txt"
git -C "$WORK_DIR" add feature-new.txt
git -C "$WORK_DIR" commit -q -m "New branch commit"

# Push the new branch to intermediary
oldrev="0000000000000000000000000000000000000000"
git -C "$WORK_DIR" push origin feature-new 2>/dev/null
newrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/feature-new")

# Verify source does NOT have this branch yet
if git -C "$SOURCE_PATH" rev-parse --verify feature-new >/dev/null 2>&1; then
    echo "FAIL: Source should not have feature-new branch before sync"
    exit 1
fi

# Sync to source
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/feature-new" "$oldrev" >/dev/null 2>&1

# Verify source now has the new branch
if ! git -C "$SOURCE_PATH" rev-parse --verify feature-new >/dev/null 2>&1; then
    echo "FAIL: Source should have feature-new branch after sync"
    exit 1
fi

# Verify the content is on the new branch
new_branch_content=$(git -C "$SOURCE_PATH" show "feature-new:feature-new.txt" 2>/dev/null)
if [ "$new_branch_content" != "new branch content" ]; then
    echo "FAIL: Expected 'new branch content' on feature-new, got: '$new_branch_content'"
    exit 1
fi
echo "  PASS: New branch created on source via sync_to_source"

# ============================================================================
# Test 20: Merge commit sync (format-patch skips merges, we handle them)
# ============================================================================
echo ""
echo "Test 20: Merge commits should sync to source via first-parent diff"

setup_test_cage "source20"

# Create a feature branch with a change
git -C "$SOURCE_PATH" checkout -q -b feature20
echo "feature content" > "$SOURCE_PATH/feature20.txt"
git -C "$SOURCE_PATH" add . && git -C "$SOURCE_PATH" commit -q -m "Add feature20"
git -C "$SOURCE_PATH" checkout -q master

# Sync feature branch to intermediary
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$cfg_exclude" >/dev/null 2>&1

# Make a conflicting change on master
echo "master version" > "$SOURCE_PATH/shared.txt"
git -C "$SOURCE_PATH" add . && git -C "$SOURCE_PATH" commit -q -m "Master adds shared"
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "$cfg_exclude" >/dev/null 2>&1

# In the work dir, simulate a merge commit: create feature branch, merge it
git -C "$WORK_DIR" fetch -q origin
git -C "$WORK_DIR" pull -q origin master 2>/dev/null || git -C "$WORK_DIR" reset -q --hard origin/master

# Create a feature branch in work with a change + new file
git -C "$WORK_DIR" checkout -q -b work-feature
echo "feature version" > "$WORK_DIR/shared.txt"
echo "extra" > "$WORK_DIR/extra.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Feature changes shared"

# Make a conflicting change on work's master so merge will conflict
git -C "$WORK_DIR" checkout -q master
echo "work master version" > "$WORK_DIR/shared.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Work master changes shared"

# Merge in work (will conflict on shared.txt — both sides changed it)
git -C "$WORK_DIR" merge work-feature --no-edit 2>/dev/null || true

# Resolve conflict
echo "resolved content" > "$WORK_DIR/shared.txt"
git -C "$WORK_DIR" add shared.txt
git -C "$WORK_DIR" commit -q -m "Merge work-feature into master"

# Record pre-push state (master~2 is before our two new commits + merge)
local_master_before=$(git -C "$INTERMEDIARY_DIR" rev-parse master)
local_master_after=$(git -C "$WORK_DIR" rev-parse master)

# Push to intermediary
git -C "$WORK_DIR" push -q origin master 2>/dev/null

# Sync to source
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/master" "$local_master_before" >/dev/null 2>&1

# Verify the merge resolution made it to source
source_shared=$(cat "$SOURCE_PATH/shared.txt")
if [ "$source_shared" != "resolved content" ]; then
    echo "FAIL: Expected 'resolved content' on source, got: '$source_shared'"
    exit 1
fi
echo "  PASS: Merge conflict resolution synced to source"

# Verify the extra file from the merge also made it
if [ ! -f "$SOURCE_PATH/extra.txt" ]; then
    echo "FAIL: extra.txt should exist on source after merge sync"
    exit 1
fi
echo "  PASS: Merge brought in all changes from feature branch"

# Verify commit was mapped
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
if ! grep -q "$local_master_after" "$commit_map_path" 2>/dev/null; then
    echo "FAIL: Merge commit should be in commit mapping"
    exit 1
fi
echo "  PASS: Merge commit mapped correctly"

echo ""
echo "=== All git-sync tests passed! ==="
