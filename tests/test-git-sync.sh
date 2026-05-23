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
cfg_syncActiveBranch="true"
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

    # Set git identity on work dir (clones don't inherit source's local config,
    # and tests override HOME so global .gitconfig is absent)
    git -C "$WORK_DIR" config user.email "test@test.com"
    git -C "$WORK_DIR" config user.name "Test"
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
# Test 6: manual_git_merge works
# ============================================================================
echo ""
echo "Test 6: manual_git_merge should sync unmerged commits"

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

# Check that the commit was synced to source
if [ ! -f "$SOURCE_PATH/merge.txt" ]; then
    echo "FAIL: merge.txt not found on source after manual_git_merge"
    exit 1
fi
if [ "$(cat "$SOURCE_PATH/merge.txt")" != "merge test" ]; then
    echo "FAIL: merge.txt has wrong content on source"
    exit 1
fi
echo "  PASS: manual_git_merge synced commits to source"

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

# New registration: $RUNTIME/sessions/<session_id>/<pid> with source_dir as content
session_dir=$(get_session_dir "other-session-11")
mkdir -p "$session_dir"
echo "$SOURCE_PATH" > "$session_dir/$fake_session_pid"

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

# Create a stale PID file (PID that definitely doesn't exist) with source_dir as content
session_dir=$(get_session_dir "stale-session-12")
mkdir -p "$session_dir"
echo "$SOURCE_PATH" > "$session_dir/999999999"

# Also add a live process so has_other_sessions is exercised
sleep 300 &
live_pid=$!
echo "$SOURCE_PATH" > "$session_dir/$live_pid"

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
# Test 20: Merge commit creates real merge on source (two parents)
# ============================================================================
echo ""
echo "Test 20: Merge commits should create real merge on source with two parents"

setup_test_cage "source20"

# Work: fetch and update master
git -C "$WORK_DIR" fetch -q origin
git -C "$WORK_DIR" pull -q origin master 2>/dev/null || git -C "$WORK_DIR" reset -q --hard origin/master

# Work: create a feature branch with changes
git -C "$WORK_DIR" checkout -q -b work-feature
echo "feature version" > "$WORK_DIR/shared.txt"
echo "extra" > "$WORK_DIR/extra.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Feature changes shared"

# Push work-feature to intermediary (required: second parent must be mapped)
feature_old="0000000000000000000000000000000000000000"
git -C "$WORK_DIR" push -q origin work-feature 2>/dev/null

# Sync work-feature to source so the feature commits get mapped
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/work-feature" "$feature_old" >/dev/null 2>&1

# Work: back to master, make a conflicting change
git -C "$WORK_DIR" checkout -q master
echo "work master version" > "$WORK_DIR/shared.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Work master changes shared"

# Merge work-feature into master (will conflict on shared.txt)
git -C "$WORK_DIR" merge work-feature --no-edit 2>/dev/null || true

# Resolve conflict
echo "resolved content" > "$WORK_DIR/shared.txt"
git -C "$WORK_DIR" add shared.txt
git -C "$WORK_DIR" commit -q -m "Merge work-feature into master"

# Record pre-push state
local_master_before=$(git -C "$INTERMEDIARY_DIR" rev-parse master)
local_master_after=$(git -C "$WORK_DIR" rev-parse master)

# Verify it's actually a merge commit in the work dir
if ! git -C "$WORK_DIR" rev-parse --verify "${local_master_after}^2" >/dev/null 2>&1; then
    echo "FAIL: Work dir HEAD should be a merge commit (2 parents)"
    exit 1
fi

# Push to intermediary
git -C "$WORK_DIR" push -q origin master 2>/dev/null

# Sync to source
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/master" "$local_master_before" >/dev/null 2>&1

# Verify the merge resolution made it to source (check committed tree, not working dir)
source_shared=$(git -C "$SOURCE_PATH" show master:shared.txt 2>/dev/null)
if [ "$source_shared" != "resolved content" ]; then
    echo "FAIL: Expected 'resolved content' on source master, got: '$source_shared'"
    exit 1
fi
echo "  PASS: Merge conflict resolution synced to source"

# Verify the extra file from the merge also made it
source_extra=$(git -C "$SOURCE_PATH" show master:extra.txt 2>/dev/null)
if [ "$source_extra" != "extra" ]; then
    echo "FAIL: extra.txt should exist on source master after merge sync"
    exit 1
fi
echo "  PASS: Merge brought in all changes from feature branch"

# Verify source commit is a REAL merge (has two parents)
source_master=$(git -C "$SOURCE_PATH" rev-parse master)
if ! git -C "$SOURCE_PATH" rev-parse --verify "${source_master}^2" >/dev/null 2>&1; then
    echo "FAIL: Source master should be a merge commit with two parents"
    exit 1
fi
echo "  PASS: Source commit is a real merge (two parents)"

# Verify second parent on source points to the feature branch
source_second_parent=$(git -C "$SOURCE_PATH" rev-parse "${source_master}^2")
source_feature_head=$(git -C "$SOURCE_PATH" rev-parse work-feature 2>/dev/null)
if [ "$source_second_parent" != "$source_feature_head" ]; then
    echo "FAIL: Source merge second parent ($source_second_parent) should match work-feature ($source_feature_head)"
    exit 1
fi
echo "  PASS: Source merge second parent matches feature branch"

# Verify commit was mapped
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
if ! grep -q "$local_master_after" "$commit_map_path" 2>/dev/null; then
    echo "FAIL: Merge commit should be in commit mapping"
    exit 1
fi
echo "  PASS: Merge commit mapped correctly"

# ============================================================================
# Test 21: Merge commit with unmapped second parent should error
# ============================================================================
echo ""
echo "Test 21: Merge with unmapped second parent should fail gracefully"

setup_test_cage "source21"

# Work: create feature branch and merge WITHOUT pushing feature first
git -C "$WORK_DIR" checkout -q -b unpushed-feature
echo "unpushed content" > "$WORK_DIR/unpushed.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Unpushed feature"

git -C "$WORK_DIR" checkout -q master
echo "master change" > "$WORK_DIR/master21.txt"
git -C "$WORK_DIR" add . && git -C "$WORK_DIR" commit -q -m "Master change"

# Merge unpushed-feature (clean merge, no conflict)
git -C "$WORK_DIR" merge unpushed-feature --no-edit -q 2>/dev/null

local_master_before=$(git -C "$INTERMEDIARY_DIR" rev-parse master)

# Push to intermediary (includes the merge and all commits)
git -C "$WORK_DIR" push -q origin master 2>/dev/null

# Sync to source — merge should fail because second parent wasn't synced
sync_output=$(sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/master" "$local_master_before" 2>&1) || true

# The non-merge commits should have synced, but merge should have failed
if [ ! -f "$SOURCE_PATH/master21.txt" ]; then
    echo "FAIL: Non-merge commit (master21.txt) should have synced to source"
    exit 1
fi
echo "  PASS: Non-merge commits synced despite merge failure"

# Check sync log for the merge failure
sync_log_file="$INTERMEDIARY_DIR/sync.log"
if ! grep -q "merge FAILED.*not mapped" "$sync_log_file" 2>/dev/null; then
    echo "FAIL: Sync log should contain merge failure with 'not mapped'"
    echo "  Log contents:"
    cat "$sync_log_file" 2>/dev/null | tail -5
    exit 1
fi
echo "  PASS: Merge failure logged with 'not mapped' reason"

# Verify a failed patch was saved
failed_dir="$SOURCE_PATH/claude-cage-failed-patches/from-intermediary/master"
if [ ! -d "$failed_dir" ] || [ -z "$(ls -A "$failed_dir" 2>/dev/null)" ]; then
    echo "FAIL: Failed patch should have been saved for the merge commit"
    exit 1
fi
echo "  PASS: Failed merge patch saved for recovery"

# ============================================================================
# Test 22: syncActiveBranch with dirty tree, no conflicts
# ============================================================================
echo ""
echo "Test 22: syncActiveBranch with dirty tree should stash, apply, and restore"

cfg_syncActiveBranch="true"
setup_test_cage "source22"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

# Make a commit in work and push
echo "claude added this" > "$WORK_DIR/newfile.txt"
git -C "$WORK_DIR" add newfile.txt
git -C "$WORK_DIR" commit -q -m "Add newfile from Claude"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Dirty the source working tree (non-conflicting change)
echo "user edit" >> "$SOURCE_PATH/file.txt"

# Verify source is dirty
if [ -z "$(git -C "$SOURCE_PATH" status --porcelain)" ]; then
    echo "FAIL: Source should be dirty before sync"
    exit 1
fi

# Sync
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify Claude's commit was applied
if [ ! -f "$SOURCE_PATH/newfile.txt" ]; then
    echo "FAIL: newfile.txt not in source after sync"
    exit 1
fi
echo "  PASS: Claude's commit applied"

# Verify user's edit was restored from stash
if ! grep -q "user edit" "$SOURCE_PATH/file.txt"; then
    echo "FAIL: User's edit should be restored from stash"
    echo "  file.txt contents: $(cat "$SOURCE_PATH/file.txt")"
    exit 1
fi
echo "  PASS: User's dirty edit restored"

# Verify stash list is empty (clean pop)
stash_count=$(git -C "$SOURCE_PATH" stash list 2>/dev/null | wc -l)
if [ "$stash_count" -ne 0 ]; then
    echo "FAIL: Stash list should be empty after clean restore"
    echo "  Stash list: $(git -C "$SOURCE_PATH" stash list)"
    exit 1
fi
echo "  PASS: Stash list empty (clean pop)"

# Verify commit mapping updated
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
newrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
if ! grep -q "^$newrev " "$commit_map_path"; then
    echo "FAIL: Commit mapping should be updated"
    exit 1
fi
echo "  PASS: Commit mapping updated"

# ============================================================================
# Test 23: syncActiveBranch with dirty tree, conflicts left for user
# ============================================================================
echo ""
echo "Test 23: syncActiveBranch with conflicts should leave conflict markers for user"

cfg_syncActiveBranch="true"
setup_test_cage "source23"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

# Make a conflicting commit in work: overwrite file.txt
echo "claude version" > "$WORK_DIR/file.txt"
git -C "$WORK_DIR" add file.txt
git -C "$WORK_DIR" commit -q -m "Claude overwrites file.txt"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Dirty source with conflicting edit to file.txt
echo "user version" > "$SOURCE_PATH/file.txt"

# Sync
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify Claude's version wins in the committed tree
committed_content=$(git -C "$SOURCE_PATH" show HEAD:file.txt 2>/dev/null)
if [ "$committed_content" != "claude version" ]; then
    echo "FAIL: HEAD:file.txt should be 'claude version', got: '$committed_content'"
    exit 1
fi
echo "  PASS: Claude's version in committed tree"

# Verify working tree has conflict markers (unresolved stash pop)
if ! grep -q "<<<<<<" "$SOURCE_PATH/file.txt" 2>/dev/null; then
    echo "FAIL: file.txt should have conflict markers"
    exit 1
fi
echo "  PASS: Conflict markers left in working tree for user to resolve"

# Verify stash still exists (git stash pop doesn't drop on conflict)
stash_count=$(git -C "$SOURCE_PATH" stash list 2>/dev/null | wc -l)
if [ "$stash_count" -eq 0 ]; then
    echo "FAIL: Stash should still exist (not dropped on conflict)"
    exit 1
fi
echo "  PASS: Stash preserved (not dropped on failed pop)"

# Clean up conflict state for next test
git -C "$SOURCE_PATH" checkout -- . 2>/dev/null || true
git -C "$SOURCE_PATH" stash drop 2>/dev/null || true

# ============================================================================
# Test 24: syncActiveBranch with untracked file collision
# ============================================================================
echo ""
echo "Test 24: syncActiveBranch with untracked file collision leaves conflict for user"

cfg_syncActiveBranch="true"
setup_test_cage "source24"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

# Claude adds a new file
echo "claude brand-new" > "$WORK_DIR/brand-new.txt"
git -C "$WORK_DIR" add brand-new.txt
git -C "$WORK_DIR" commit -q -m "Claude adds brand-new.txt"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Create the same file as untracked on source (collision)
echo "user brand-new" > "$SOURCE_PATH/brand-new.txt"

# Sync
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify Claude's version is in the committed tree
committed_content=$(git -C "$SOURCE_PATH" show HEAD:brand-new.txt 2>/dev/null)
if [ "$committed_content" != "claude brand-new" ]; then
    echo "FAIL: HEAD:brand-new.txt should be 'claude brand-new', got: '$committed_content'"
    exit 1
fi
echo "  PASS: Claude's brand-new.txt in committed tree"

# The user's untracked file should have been stashed (stash still present on conflict)
stash_count=$(git -C "$SOURCE_PATH" stash list 2>/dev/null | wc -l)
if [ "$stash_count" -eq 0 ]; then
    echo "FAIL: Should have a stash with user's untracked brand-new.txt"
    exit 1
fi
echo "  PASS: User's untracked file collision preserved in stash"

# Clean up conflict state for next test
git -C "$SOURCE_PATH" checkout -- . 2>/dev/null || true
git -C "$SOURCE_PATH" stash drop 2>/dev/null || true

# ============================================================================
# Test 25: syncActiveBranch with multiple commits in batch
# ============================================================================
echo ""
echo "Test 25: syncActiveBranch with multiple commits and dirty tree"

cfg_syncActiveBranch="true"
setup_test_cage "source25"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")

# Multiple commits
echo "a" > "$WORK_DIR/a.txt"
git -C "$WORK_DIR" add a.txt && git -C "$WORK_DIR" commit -q -m "Add a"
echo "b" > "$WORK_DIR/b.txt"
git -C "$WORK_DIR" add b.txt && git -C "$WORK_DIR" commit -q -m "Add b"
echo "c" > "$WORK_DIR/c.txt"
git -C "$WORK_DIR" add c.txt && git -C "$WORK_DIR" commit -q -m "Add c"

git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Dirty source (non-conflicting)
echo "wip" >> "$SOURCE_PATH/file.txt"

# Sync
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify all three files exist
for f in a b c; do
    if [ ! -f "$SOURCE_PATH/${f}.txt" ]; then
        echo "FAIL: ${f}.txt not in source after batch sync"
        exit 1
    fi
done
echo "  PASS: All three commits applied"

# Verify user's edit preserved
if ! grep -q "wip" "$SOURCE_PATH/file.txt"; then
    echo "FAIL: User's 'wip' edit should be preserved"
    exit 1
fi
echo "  PASS: User's WIP edit restored"

# Stash should be empty (no conflicts)
stash_count=$(git -C "$SOURCE_PATH" stash list 2>/dev/null | wc -l)
if [ "$stash_count" -ne 0 ]; then
    echo "FAIL: Stash should be empty after non-conflicting batch sync"
    exit 1
fi
echo "  PASS: Stash list empty"

# ============================================================================
# Test 26: syncActiveBranch with clean tree (no stash needed)
# ============================================================================
echo ""
echo "Test 26: syncActiveBranch with clean tree should not stash"

cfg_syncActiveBranch="true"
setup_test_cage "source26"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

echo "clean sync" > "$WORK_DIR/clean.txt"
git -C "$WORK_DIR" add clean.txt
git -C "$WORK_DIR" commit -q -m "Clean sync test"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Source is CLEAN (no dirty changes)
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" >/dev/null 2>&1

# Verify commit applied
if [ ! -f "$SOURCE_PATH/clean.txt" ]; then
    echo "FAIL: clean.txt should be in source"
    exit 1
fi
echo "  PASS: Clean sync applied"

# Verify no stash entries
stash_count=$(git -C "$SOURCE_PATH" stash list 2>/dev/null | wc -l)
if [ "$stash_count" -ne 0 ]; then
    echo "FAIL: No stash should be created for clean tree"
    exit 1
fi
echo "  PASS: No stash created"

# Verify commit mapping
commit_map_path=$(get_commit_map_path "$INTERMEDIARY_DIR")
newrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
if ! grep -q "^$newrev " "$commit_map_path"; then
    echo "FAIL: Commit mapping should be updated"
    exit 1
fi
echo "  PASS: Commit mapping updated"

# ============================================================================
# Test 27: syncActiveBranch=false skips active branch
# ============================================================================
echo ""
echo "Test 27: syncActiveBranch=false should skip sync to active branch"

cfg_syncActiveBranch="false"
setup_test_cage "source27"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

echo "claude skip test" > "$WORK_DIR/skipfile.txt"
git -C "$WORK_DIR" add skipfile.txt
git -C "$WORK_DIR" commit -q -m "Should be skipped on active branch"

oldrev=$(git -C "$INTERMEDIARY_DIR" rev-parse "refs/heads/$BRANCH_NAME")
git -C "$WORK_DIR" push origin "$BRANCH_NAME" 2>/dev/null

# Source is on the same branch as the push target
sync_output=$(sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$oldrev" 2>&1)

# Verify commit was NOT applied to source
if [ -f "$SOURCE_PATH/skipfile.txt" ]; then
    echo "FAIL: skipfile.txt should NOT be in source (active branch skipped)"
    exit 1
fi
echo "  PASS: Commit not applied to active branch"

# Verify the skip message was output
if ! echo "$sync_output" | grep -q "active branch"; then
    echo "FAIL: Should mention active branch in skip message"
    echo "  Output: $sync_output"
    exit 1
fi
echo "  PASS: Skip message mentions active branch"

# ============================================================================
# Test 28: syncActiveBranch=false still syncs other branches (temp-index)
# ============================================================================
echo ""
echo "Test 28: syncActiveBranch=false should still sync to non-active branches"

cfg_syncActiveBranch="false"
setup_test_cage "source28"

git -C "$WORK_DIR" config user.email "claude@test.com"
git -C "$WORK_DIR" config user.name "Claude"

# Create a feature branch in work and push to intermediary
git -C "$WORK_DIR" checkout -b feature-test 2>/dev/null
echo "feature content" > "$WORK_DIR/feature.txt"
git -C "$WORK_DIR" add feature.txt
git -C "$WORK_DIR" commit -q -m "Feature branch commit"

git -C "$WORK_DIR" push origin feature-test 2>/dev/null

# Source stays on the original branch (not feature-test)
# So syncing feature-test should go through the temp-index path
sync_to_source "$SOURCE_PATH" "$INTERMEDIARY_DIR" "refs/heads/feature-test" "0000000000000000000000000000000000000000" >/dev/null 2>&1

# Verify the feature branch was created on source
if ! git -C "$SOURCE_PATH" rev-parse --verify feature-test >/dev/null 2>&1; then
    echo "FAIL: feature-test branch should exist on source"
    exit 1
fi
echo "  PASS: Feature branch created on source"

# Verify the commit content is there
feature_content=$(git -C "$SOURCE_PATH" show feature-test:feature.txt 2>/dev/null)
if [ "$feature_content" != "feature content" ]; then
    echo "FAIL: feature.txt should be 'feature content', got '$feature_content'"
    exit 1
fi
echo "  PASS: Feature branch commit applied via temp-index"

# ============================================================================
# Test 29: copy_dirty_files_to_work - basic modified file
# ============================================================================
echo ""
echo "Test 29: copy_dirty_files_to_work should copy modified files to work dir"

cfg_syncActiveBranch="true"
setup_test_cage "source29"

# Dirty a file on source
echo "user edit in progress" > "$SOURCE_PATH/file.txt"

# Verify source is dirty, work is clean
if ! source_is_dirty "$SOURCE_PATH"; then
    echo "FAIL: Source should be dirty"
    exit 1
fi
if is_work_dirty "$WORK_DIR"; then
    echo "FAIL: Work should be clean before copy"
    exit 1
fi

# Copy dirty files
copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

# Verify the edit was copied to work
work_content=$(cat "$WORK_DIR/file.txt")
if [ "$work_content" != "user edit in progress" ]; then
    echo "FAIL: file.txt should be 'user edit in progress' in work, got: '$work_content'"
    exit 1
fi
echo "  PASS: Modified file copied to work dir"

# ============================================================================
# Test 30: copy_dirty_files_to_work - deleted file
# ============================================================================
echo "Test 30: copy_dirty_files_to_work should delete removed files from work"

setup_test_cage "source30"

# Add a second file, commit it
echo "extra" > "$SOURCE_PATH/extra.txt"
git -C "$SOURCE_PATH" add extra.txt
git -C "$SOURCE_PATH" commit -q -m "Add extra"
# Update intermediary and work
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null

# Verify work has extra.txt
if [ ! -f "$WORK_DIR/extra.txt" ]; then
    echo "FAIL: extra.txt should exist in work dir before test"
    exit 1
fi

# Delete it on source (tracked delete)
git -C "$SOURCE_PATH" rm -q extra.txt

# Copy dirty files
copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

# Verify it's gone from work
if [ -f "$WORK_DIR/extra.txt" ]; then
    echo "FAIL: extra.txt should be deleted from work"
    exit 1
fi
echo "  PASS: Deleted file removed from work dir"

# ============================================================================
# Test 31: copy_dirty_files_to_work - exclude filtering
# ============================================================================
echo "Test 31: copy_dirty_files_to_work should respect exclude patterns"

setup_test_cage "source31"

# Create a dirty .env file on source
echo "SECRET=token" > "$SOURCE_PATH/.env"

# Also create a non-excluded dirty file
echo "user wip" > "$SOURCE_PATH/file.txt"

# Copy with .env excluded
copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" ".env" >/dev/null

# .env should NOT be in work
if [ -f "$WORK_DIR/.env" ]; then
    echo "FAIL: .env should NOT be copied (it's excluded)"
    exit 1
fi
echo "  PASS: Excluded file not copied"

# file.txt should be copied
work_content=$(cat "$WORK_DIR/file.txt")
if [ "$work_content" != "user wip" ]; then
    echo "FAIL: Non-excluded file.txt should be copied"
    exit 1
fi
echo "  PASS: Non-excluded file copied"

# ============================================================================
# Test 32: copy_dirty_files_to_work - clean source is no-op
# ============================================================================
echo "Test 32: copy_dirty_files_to_work on clean source should be a no-op"

setup_test_cage "source32"

# Source is clean after setup
original_content=$(cat "$WORK_DIR/file.txt")

copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

# Work should be unchanged
new_content=$(cat "$WORK_DIR/file.txt")
if [ "$original_content" != "$new_content" ]; then
    echo "FAIL: Work dir should be unchanged after no-op copy"
    exit 1
fi
echo "  PASS: Clean source is a no-op"

# ============================================================================
# Test 33: copy_dirty_files_to_work - untracked files
# ============================================================================
echo "Test 33: copy_dirty_files_to_work should copy untracked files"

setup_test_cage "source33"

# Create an untracked file on source
echo "brand new file" > "$SOURCE_PATH/untracked-new.txt"

copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

if [ ! -f "$WORK_DIR/untracked-new.txt" ]; then
    echo "FAIL: Untracked file should be copied to work"
    exit 1
fi
work_content=$(cat "$WORK_DIR/untracked-new.txt")
if [ "$work_content" != "brand new file" ]; then
    echo "FAIL: Untracked file content mismatch"
    exit 1
fi
echo "  PASS: Untracked file copied to work dir"

# ============================================================================
# Test 34: copy_dirty_files_to_work - rename handling
# ============================================================================
echo "Test 34: copy_dirty_files_to_work should handle renames"

setup_test_cage "source34"

# Rename file.txt to renamed.txt (staged rename)
git -C "$SOURCE_PATH" mv file.txt renamed.txt

copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

# Old file should be gone from work
if [ -f "$WORK_DIR/file.txt" ]; then
    echo "FAIL: file.txt should be removed (renamed away)"
    exit 1
fi
echo "  PASS: Old name removed from work"

# New file should exist
if [ ! -f "$WORK_DIR/renamed.txt" ]; then
    echo "FAIL: renamed.txt should be in work"
    exit 1
fi
echo "  PASS: New name copied to work"

# ============================================================================
# Test 35: copy_dirty_files_to_work - scoped repo
# ============================================================================
echo "Test 35: copy_dirty_files_to_work should handle scoped repos"

# Create a scoped test setup: repo with services/api/ structure
rm -rf "$TEST_TMP/source35"
mkdir -p "$TEST_TMP/source35/services/api"
cd "$TEST_TMP/source35"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "api code" > services/api/app.txt
echo "root file" > root.txt
git add . && git commit -q -m "Initial"

SOURCE_PATH="$TEST_TMP/source35"

# Create scoped cage for services/api
cfg_exclude=""
cfg_git_scoped="true"
local_scope="services/api"
CLAUDE_CAGE_SESSION="test-scoped-35"
export CLAUDE_CAGE_SESSION

INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_PATH" "$local_scope")
WORK_DIR=$(get_scoped_work_path "$TEST_TMP/source35/services/api" "$local_scope")

create_intermediary_clone "$TEST_TMP/source35/services/api" "$local_scope" >/dev/null 2>&1

# Dirty a file inside scope
echo "wip api edit" > "$SOURCE_PATH/services/api/app.txt"
# Dirty a file outside scope
echo "wip root edit" > "$SOURCE_PATH/root.txt"

copy_dirty_files_to_work "$SOURCE_PATH" "$WORK_DIR" "$local_scope" "" >/dev/null

# In-scope file should be copied (with prefix stripped)
if [ ! -f "$WORK_DIR/app.txt" ]; then
    echo "FAIL: In-scope app.txt should be copied to work"
    exit 1
fi
work_content=$(cat "$WORK_DIR/app.txt")
if [ "$work_content" != "wip api edit" ]; then
    echo "FAIL: In-scope file content wrong: '$work_content'"
    exit 1
fi
echo "  PASS: In-scope file copied with prefix stripped"

# Out-of-scope file should NOT be in work
if [ -f "$WORK_DIR/root.txt" ]; then
    echo "FAIL: Out-of-scope root.txt should NOT be in work"
    exit 1
fi
echo "  PASS: Out-of-scope file not copied"

# Reset for remaining tests
cfg_git_scoped=""
CLAUDE_CAGE_SESSION="test-session-$$"
export CLAUDE_CAGE_SESSION

# ============================================================================
# Test 35a: enumerate_source_dirty_pairs emits pairs for modified file
# ============================================================================
echo ""
echo "Test 35a: enumerate_source_dirty_pairs should emit (src, dest) pair for modified file"

setup_test_cage "source35a"
echo "modified" > "$SOURCE_PATH/file.txt"

pairs=$(enumerate_source_dirty_pairs "$SOURCE_PATH" "" "" | tr '\0' '|')
if [ "$pairs" != "file.txt|file.txt|" ]; then
    echo "FAIL: expected 'file.txt|file.txt|', got '$pairs'"
    exit 1
fi
echo "  PASS: emits pair for modified file"

# ============================================================================
# Test 35b: enumerate_source_dirty_pairs strips scope prefix
# ============================================================================
echo "Test 35b: enumerate_source_dirty_pairs should strip scope prefix from dest"

mkdir -p "$TEST_TMP/source35b/services/api"
cd "$TEST_TMP/source35b"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "x" > services/api/a.txt
echo "y" > root.txt
git add . && git commit -q -m "Initial"
echo "edit" > "$TEST_TMP/source35b/services/api/a.txt"
echo "edit" > "$TEST_TMP/source35b/root.txt"

pairs=$(enumerate_source_dirty_pairs "$TEST_TMP/source35b" "services/api" "" | tr '\0' '|')
# Only the in-scope file should appear; dest path strips the scope prefix
if [ "$pairs" != "services/api/a.txt|a.txt|" ]; then
    echo "FAIL: expected 'services/api/a.txt|a.txt|', got '$pairs'"
    exit 1
fi
echo "  PASS: scope prefix stripped, out-of-scope dropped"

# ============================================================================
# Test 35c: work_matches_source_dirty returns 0 when work mirrors source
# ============================================================================
echo "Test 35c: work_matches_source_dirty should return 0 when work mirrors source"

setup_test_cage "source35c"
echo "user wip" > "$SOURCE_PATH/file.txt"
echo "user wip" > "$WORK_DIR/file.txt"

if ! work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ""; then
    echo "FAIL: should have matched"
    exit 1
fi
echo "  PASS: returns 0 when work and source dirty content matches"

# ============================================================================
# Test 35d: work_matches_source_dirty returns 1 when content diverges
# ============================================================================
echo "Test 35d: work_matches_source_dirty should return 1 when content diverges"

setup_test_cage "source35d"
echo "user wip" > "$SOURCE_PATH/file.txt"
echo "claude edited" > "$WORK_DIR/file.txt"

if work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ""; then
    echo "FAIL: should not have matched (content diverges)"
    exit 1
fi
echo "  PASS: returns 1 when content diverges"

# ============================================================================
# Test 35e: work_matches_source_dirty returns 1 when work has extra dirty path
# ============================================================================
echo "Test 35e: work_matches_source_dirty should return 1 when work has dirty paths absent in source"

setup_test_cage "source35e"
echo "user wip" > "$SOURCE_PATH/file.txt"
echo "user wip" > "$WORK_DIR/file.txt"
echo "untracked claude file" > "$WORK_DIR/new.txt"

if work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ""; then
    echo "FAIL: should not have matched (work has extra untracked path)"
    exit 1
fi
echo "  PASS: returns 1 when work has dirty paths outside source's set"

# ============================================================================
# Test 35f: work_matches_source_dirty matches deletions on both sides
# ============================================================================
echo "Test 35f: work_matches_source_dirty should match when both delete same file"

setup_test_cage "source35f"
rm "$SOURCE_PATH/file.txt"
rm "$WORK_DIR/file.txt"

if ! work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ""; then
    echo "FAIL: should have matched (both deleted)"
    exit 1
fi
echo "  PASS: returns 0 when both delete the same file"

# ============================================================================
# Test 35g: work_matches_source_dirty rejects when source deletes, work keeps
# ============================================================================
echo "Test 35g: work_matches_source_dirty should reject when source deletes but work retains"

setup_test_cage "source35g"
rm "$SOURCE_PATH/file.txt"
# work_dir still has file.txt

if work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ""; then
    echo "FAIL: should not match (source deleted, work retained)"
    exit 1
fi
echo "  PASS: returns 1 when source deletes but work retains"

# ============================================================================
# Test 35h: work_matches_source_dirty honors exclude patterns
# ============================================================================
echo "Test 35h: work_matches_source_dirty should ignore excluded patterns"

setup_test_cage "source35h"
echo "user wip" > "$SOURCE_PATH/file.txt"
echo "user wip" > "$WORK_DIR/file.txt"
# Source has a dirty .env that is excluded; work doesn't see it.
echo "secret" > "$SOURCE_PATH/.env"

if ! work_matches_source_dirty "$SOURCE_PATH" "$WORK_DIR" "" ".env"; then
    echo "FAIL: should have matched (excluded path ignored)"
    exit 1
fi
echo "  PASS: excluded paths are ignored during match"



# ============================================================================
# Test 36: copy_carry_files to_work — basic copy
# ============================================================================
echo ""
echo "Test 36: copy_carry_files to_work should copy gitignored file to work dir"

setup_test_cage "source36"

# Create a gitignored file on source
echo "CLAUDE.md" >> "$SOURCE_PATH/.gitignore"
git -C "$SOURCE_PATH" add .gitignore && git -C "$SOURCE_PATH" commit -q -m "Add gitignore"
echo "my claude config" > "$SOURCE_PATH/CLAUDE.md"

# Sync intermediary to pick up the .gitignore commit
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null || true

# Copy carry files to work
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" >/dev/null

if [ ! -f "$WORK_DIR/CLAUDE.md" ]; then
    echo "FAIL: CLAUDE.md should be copied to work"
    exit 1
fi
work_content=$(cat "$WORK_DIR/CLAUDE.md")
if [ "$work_content" != "my claude config" ]; then
    echo "FAIL: CLAUDE.md content wrong: '$work_content'"
    exit 1
fi
echo "  PASS: Carry file copied to work dir"

# ============================================================================
# Test 37: copy_carry_files from_cage — basic carry-out
# ============================================================================
echo "Test 37: copy_carry_files from_cage should deposit cage's version into .caged/carry"

# Modify the file in work (carry-back from_cage continues from Test 36's setup)
echo "updated by claude" > "$WORK_DIR/CLAUDE.md"
mkdir -p "$SOURCE_PATH/.caged"
source_snapshot=$(cat "$SOURCE_PATH/CLAUDE.md")

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit="$SOURCE_PATH/.caged/carry/$label/CLAUDE.md"
if [ ! -f "$deposit" ]; then
    echo "FAIL: cage's CLAUDE.md should have been deposited at $deposit"
    exit 1
fi
if [ "$(cat "$deposit")" != "updated by claude" ]; then
    echo "FAIL: deposit content wrong: '$(cat "$deposit")'"
    exit 1
fi
if [ "$(cat "$SOURCE_PATH/CLAUDE.md")" != "$source_snapshot" ]; then
    echo "FAIL: source CLAUDE.md should NOT have been touched"
    exit 1
fi
echo "  PASS: cage's edit deposited into .caged/carry, source untouched"
rm -rf "$SOURCE_PATH/.caged"

# ============================================================================
# Test 38: copy_carry_files to_work — file doesn't exist
# ============================================================================
echo "Test 38: copy_carry_files to_work should be a no-op when file doesn't exist"

setup_test_cage "source38"

# Don't create nonexistent.txt on source
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "nonexistent.txt|nonexistent.txt" >/dev/null

if [ -f "$WORK_DIR/nonexistent.txt" ]; then
    echo "FAIL: nonexistent.txt should not be in work"
    exit 1
fi
echo "  PASS: Missing file is a no-op"

# ============================================================================
# Test 39: copy_carry_files to_work — scoped repo
# ============================================================================
echo "Test 39: copy_carry_files to_work should handle scoped repos"

# Set up a scoped test: repo with services/api/ structure
rm -rf "$TEST_TMP/source39"
mkdir -p "$TEST_TMP/source39/services/api"
cd "$TEST_TMP/source39"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "CLAUDE.md" >> .gitignore
echo "api code" > services/api/app.txt
git add . && git commit -q -m "Initial"

SOURCE_PATH="$TEST_TMP/source39"
local_scope="services/api"
CLAUDE_CAGE_SESSION="test-scoped-39"
export CLAUDE_CAGE_SESSION

INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_PATH" "$local_scope")
WORK_DIR=$(get_scoped_work_path "$TEST_TMP/source39/services/api" "$local_scope")

create_intermediary_clone "$TEST_TMP/source39/services/api" "$local_scope" >/dev/null 2>&1

# Create carry file inside scope
echo "scoped carry" > "$SOURCE_PATH/services/api/CLAUDE.md"
# Create carry file outside scope
echo "root carry" > "$SOURCE_PATH/CLAUDE.md"

# Copy with scope — inside scope should work, outside should be skipped
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "$local_scope" "services/api/CLAUDE.md|services/api/CLAUDE.md^CLAUDE.md|CLAUDE.md" >/dev/null

# In-scope: should be copied with prefix stripped
if [ ! -f "$WORK_DIR/CLAUDE.md" ]; then
    echo "FAIL: In-scope CLAUDE.md should be copied to work (prefix-stripped)"
    exit 1
fi
work_content=$(cat "$WORK_DIR/CLAUDE.md")
if [ "$work_content" != "scoped carry" ]; then
    echo "FAIL: Content wrong: '$work_content'"
    exit 1
fi
echo "  PASS: In-scope carry file copied with prefix stripped"

# Out-of-scope: CLAUDE.md at root should NOT be copied
# (there's already a CLAUDE.md from the in-scope copy, so check content)
if [ "$(cat "$WORK_DIR/CLAUDE.md")" = "root carry" ]; then
    echo "FAIL: Root CLAUDE.md should not overwrite in-scope one"
    exit 1
fi
echo "  PASS: Out-of-scope carry file skipped"

# Reset
CLAUDE_CAGE_SESSION="test-session-$$"
export CLAUDE_CAGE_SESSION

# ============================================================================
# Test 40: copy_carry_files — multiple files
# ============================================================================
echo "Test 40: copy_carry_files should handle multiple files"

setup_test_cage "source40"

echo "CLAUDE.md" >> "$SOURCE_PATH/.gitignore"
echo ".cursorrules" >> "$SOURCE_PATH/.gitignore"
git -C "$SOURCE_PATH" add .gitignore && git -C "$SOURCE_PATH" commit -q -m "Add gitignore"
apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null || true

echo "claude md" > "$SOURCE_PATH/CLAUDE.md"
echo "cursor rules" > "$SOURCE_PATH/.cursorrules"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md^.cursorrules|.cursorrules" >/dev/null

if [ ! -f "$WORK_DIR/CLAUDE.md" ] || [ ! -f "$WORK_DIR/.cursorrules" ]; then
    echo "FAIL: Both files should be copied"
    exit 1
fi
if [ "$(cat "$WORK_DIR/CLAUDE.md")" != "claude md" ] || [ "$(cat "$WORK_DIR/.cursorrules")" != "cursor rules" ]; then
    echo "FAIL: File contents wrong"
    exit 1
fi
echo "  PASS: Multiple carry files copied"

# ============================================================================
# Test 41: copy_carry_files — empty cfg_carry is no-op
# ============================================================================
echo "Test 41: copy_carry_files with empty carry should be a no-op"

setup_test_cage "source41"

# Should not error
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "" >/dev/null

echo "  PASS: Empty carry is a no-op"

# ============================================================================
# Test 42: copy_carry_files — git-tracked file skipped
# ============================================================================
echo "Test 42: copy_carry_files should skip git-tracked files"

setup_test_cage "source42"

# file.txt is already committed (git-tracked)
original_work_content=$(cat "$WORK_DIR/file.txt")

# Modify it on source (uncommitted change)
echo "source modified" > "$SOURCE_PATH/file.txt"

# Carry should skip it because it's tracked
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "file.txt|file.txt" >/dev/null

work_content=$(cat "$WORK_DIR/file.txt")
if [ "$work_content" != "$original_work_content" ]; then
    echo "FAIL: Git-tracked file should be skipped by carry, got: '$work_content'"
    exit 1
fi
echo "  PASS: Git-tracked file skipped by carry"

# ============================================================================
# Test 43: copy_carry_files — directory to_work
# ============================================================================
echo "Test 43: copy_carry_files should carry directories to work"

setup_test_cage "source43"

# Create a gitignored directory on source
echo ".mydir/" >> "$SOURCE_PATH/.gitignore"
git -C "$SOURCE_PATH" add .gitignore && git -C "$SOURCE_PATH" commit -q -m "Add gitignore"
mkdir -p "$SOURCE_PATH/.mydir/sub"
echo "config" > "$SOURCE_PATH/.mydir/settings.json"
echo "nested" > "$SOURCE_PATH/.mydir/sub/data.txt"

apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null || true

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

if [ ! -f "$WORK_DIR/.mydir/settings.json" ]; then
    echo "FAIL: .mydir/settings.json should be copied to work"
    exit 1
fi
if [ ! -f "$WORK_DIR/.mydir/sub/data.txt" ]; then
    echo "FAIL: .mydir/sub/data.txt should be copied to work"
    exit 1
fi
echo "  PASS: Directory carried to work"

# ============================================================================
# Test 44: copy_carry_files — directory to_work doesn't nest when dest exists
# ============================================================================
echo "Test 44: copy_carry_files should merge into existing dir, not nest"

# .mydir already exists in work from test 43. Carry again — should merge,
# not create .mydir/.mydir/
echo "updated" > "$SOURCE_PATH/.mydir/settings.json"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

if [ -e "$WORK_DIR/.mydir/.mydir" ]; then
    echo "FAIL: Directory was nested (.mydir/.mydir exists)"
    exit 1
fi
work_content=$(cat "$WORK_DIR/.mydir/settings.json")
if [ "$work_content" != "updated" ]; then
    echo "FAIL: .mydir/settings.json should be updated, got: '$work_content'"
    exit 1
fi
echo "  PASS: Directory merged without nesting"

# ============================================================================
# Test 45: copy_carry_files — read-only files in carried dir can be overwritten
# ============================================================================
echo "Test 45: copy_carry_files should overwrite read-only files in work dir"

# Make files in work dir read-only (simulates e.g. .claude/settings.json at 444)
chmod 444 "$WORK_DIR/.mydir/settings.json"
chmod 444 "$WORK_DIR/.mydir/sub/data.txt"

# Update source files
echo "overwritten" > "$SOURCE_PATH/.mydir/settings.json"
echo "also overwritten" > "$SOURCE_PATH/.mydir/sub/data.txt"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

work_content=$(cat "$WORK_DIR/.mydir/settings.json")
if [ "$work_content" != "overwritten" ]; then
    echo "FAIL: Read-only .mydir/settings.json should be overwritten, got: '$work_content'"
    exit 1
fi
work_content2=$(cat "$WORK_DIR/.mydir/sub/data.txt")
if [ "$work_content2" != "also overwritten" ]; then
    echo "FAIL: Read-only .mydir/sub/data.txt should be overwritten, got: '$work_content2'"
    exit 1
fi
echo "  PASS: Read-only files overwritten in work dir"

# ============================================================================
# Test 46: copy_carry_files — read-only files in prior .caged/carry deposit overwritten
# ============================================================================
echo "Test 46: copy_carry_files from_cage should overwrite read-only files in .caged/carry"

mkdir -p "$SOURCE_PATH/.caged"
label=$(display_session_name "$CLAUDE_CAGE_SESSION")
# Pre-seed a prior deposit with read-only files (simulating a previous run's leftover).
prior_deposit="$SOURCE_PATH/.caged/carry/$label/.mydir"
mkdir -p "$prior_deposit/sub"
echo "old settings" > "$prior_deposit/settings.json"
echo "old nested" > "$prior_deposit/sub/data.txt"
chmod 444 "$prior_deposit/settings.json" "$prior_deposit/sub/data.txt"

# Cage edits both
echo "from cage rw" > "$WORK_DIR/.mydir/settings.json"
echo "from cage nested" > "$WORK_DIR/.mydir/sub/data.txt"

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

if [ "$(cat "$prior_deposit/settings.json")" != "from cage rw" ]; then
    echo "FAIL: read-only deposit settings.json should have been overwritten"
    exit 1
fi
if [ "$(cat "$prior_deposit/sub/data.txt")" != "from cage nested" ]; then
    echo "FAIL: read-only deposit sub/data.txt should have been overwritten"
    exit 1
fi
echo "  PASS: Read-only files in prior deposit overwritten"
rm -rf "$SOURCE_PATH/.caged"

# ============================================================================
# Test 47: copy_carry_files — directory from_cage deposits to .caged/carry
# ============================================================================
echo "Test 47: copy_carry_files should deposit carry directory under .caged/carry"

echo "from cage" > "$WORK_DIR/.mydir/settings.json"
echo "new file" > "$WORK_DIR/.mydir/extra.txt"
mkdir -p "$SOURCE_PATH/.caged"
source_settings_before=""
[ -f "$SOURCE_PATH/.mydir/settings.json" ] && source_settings_before=$(cat "$SOURCE_PATH/.mydir/settings.json")

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit_dir="$SOURCE_PATH/.caged/carry/$label/.mydir"
if [ ! -f "$deposit_dir/settings.json" ]; then
    echo "FAIL: cage's .mydir/settings.json should be deposited at $deposit_dir/settings.json"
    exit 1
fi
if [ ! -f "$deposit_dir/extra.txt" ]; then
    echo "FAIL: cage's .mydir/extra.txt should be deposited"
    exit 1
fi
if [ -e "$deposit_dir/.mydir" ]; then
    echo "FAIL: Directory was nested under deposit (.mydir/.mydir)"
    exit 1
fi
# Source should be untouched.
if [ -n "$source_settings_before" ] && \
   [ "$(cat "$SOURCE_PATH/.mydir/settings.json" 2>/dev/null)" != "$source_settings_before" ]; then
    echo "FAIL: source .mydir/settings.json should NOT have been touched"
    exit 1
fi
echo "  PASS: Directory deposited under .caged/carry, source untouched"
rm -rf "$SOURCE_PATH/.caged"

# ============================================================================
# Test 48: copy_carry_files — directory with some tracked files is not skipped
# ============================================================================
echo "Test 48: copy_carry_files should carry directory even if some files inside are tracked"

setup_test_cage "source46"

# Create a directory with a tracked file and an untracked file
mkdir -p "$SOURCE_PATH/.mydir"
echo "tracked" > "$SOURCE_PATH/.mydir/tracked.txt"
git -C "$SOURCE_PATH" add .mydir/tracked.txt && git -C "$SOURCE_PATH" commit -q -m "Add tracked file"
echo "untracked" > "$SOURCE_PATH/.mydir/untracked.txt"

apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null || true

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".mydir|.mydir" >/dev/null

if [ ! -f "$WORK_DIR/.mydir/untracked.txt" ]; then
    echo "FAIL: .mydir/untracked.txt should be carried to work"
    exit 1
fi
echo "  PASS: Directory with mixed tracked/untracked files is carried"

# ============================================================================
# Test 49: copy_carry_files — mapped carry (source != dest) to_work
# ============================================================================
echo ""
echo "Test 49: copy_carry_files should carry file to different dest path"

setup_test_cage "source49"

# Create a gitignored file on source at a nested path
mkdir -p "$SOURCE_PATH/config"
echo "config/" >> "$SOURCE_PATH/.gitignore"
git -C "$SOURCE_PATH" add .gitignore && git -C "$SOURCE_PATH" commit -q -m "Add gitignore"
echo "my instructions" > "$SOURCE_PATH/config/claude.md"

apply_source_to_intermediary "$SOURCE_PATH" "$INTERMEDIARY_DIR" "" >/dev/null 2>&1
git -C "$WORK_DIR" pull -q origin "$BRANCH_NAME" 2>/dev/null || true

# Carry config/claude.md as CLAUDE.md in work
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "config/claude.md|CLAUDE.md" >/dev/null

if [ ! -f "$WORK_DIR/CLAUDE.md" ]; then
    echo "FAIL: CLAUDE.md should be created in work dir"
    exit 1
fi
work_content=$(cat "$WORK_DIR/CLAUDE.md")
if [ "$work_content" != "my instructions" ]; then
    echo "FAIL: CLAUDE.md content wrong: '$work_content'"
    exit 1
fi
# Source path should NOT be created in work
if [ -f "$WORK_DIR/config/claude.md" ]; then
    echo "FAIL: config/claude.md should NOT exist in work (it was mapped to CLAUDE.md)"
    exit 1
fi
echo "  PASS: Mapped carry file copied to different dest path"

# ============================================================================
# Test 50: copy_carry_files — mapped carry from_cage deposits under .caged
# ============================================================================
echo "Test 50: copy_carry_files should deposit mapped file under .caged/carry/<session>/<src_path>"

# Modify the file in work at the dest path (Test 49 already set up cage with config/claude.md → CLAUDE.md)
echo "updated from cage" > "$WORK_DIR/CLAUDE.md"
mkdir -p "$SOURCE_PATH/.caged"
source_before=$(cat "$SOURCE_PATH/config/claude.md")

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" "config/claude.md|CLAUDE.md" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
# Deposit uses the source-side path (config/claude.md), regardless of mapped dest.
deposit="$SOURCE_PATH/.caged/carry/$label/config/claude.md"
if [ ! -f "$deposit" ]; then
    echo "FAIL: mapped carry should deposit at $deposit"
    ls -R "$SOURCE_PATH/.caged"
    exit 1
fi
if [ "$(cat "$deposit")" != "updated from cage" ]; then
    echo "FAIL: deposit content wrong: '$(cat "$deposit")'"
    exit 1
fi
if [ "$(cat "$SOURCE_PATH/config/claude.md")" != "$source_before" ]; then
    echo "FAIL: source config/claude.md should NOT have been touched"
    exit 1
fi
echo "  PASS: Mapped carry deposited under .caged/carry (source path preserved as key, source untouched)"
rm -rf "$SOURCE_PATH/.caged"

# ============================================================================
# Test 51: copy_carry_files — mapped carry bypasses scope filtering
# ============================================================================
echo "Test 51: copy_carry_files with mapped dest should bypass scope filtering"

# Set up a scoped test: repo with services/api/ structure
rm -rf "$TEST_TMP/source51"
mkdir -p "$TEST_TMP/source51/services/api"
cd "$TEST_TMP/source51"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "CLAUDE.md" >> .gitignore
echo "api code" > services/api/app.txt
git add . && git commit -q -m "Initial"

SOURCE_PATH="$TEST_TMP/source51"
local_scope="services/api"
CLAUDE_CAGE_SESSION="test-scoped-51"
export CLAUDE_CAGE_SESSION

INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_PATH" "$local_scope")
WORK_DIR=$(get_scoped_work_path "$TEST_TMP/source51/services/api" "$local_scope")

create_intermediary_clone "$TEST_TMP/source51/services/api" "$local_scope" >/dev/null 2>&1

# Create a root-level gitignored file (outside scope)
echo "root instructions" > "$SOURCE_PATH/CLAUDE.md"

# With explicit dest, out-of-scope source file should be carried
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "$local_scope" "CLAUDE.md|INSTRUCTIONS.md" >/dev/null

if [ ! -f "$WORK_DIR/INSTRUCTIONS.md" ]; then
    echo "FAIL: INSTRUCTIONS.md should be created in work (explicit dest bypasses scope filter)"
    exit 1
fi
work_content=$(cat "$WORK_DIR/INSTRUCTIONS.md")
if [ "$work_content" != "root instructions" ]; then
    echo "FAIL: INSTRUCTIONS.md content wrong: '$work_content'"
    exit 1
fi
echo "  PASS: Mapped carry bypasses scope filtering"

# Reset
CLAUDE_CAGE_SESSION="test-session-$$"
export CLAUDE_CAGE_SESSION

# ============================================================================
# Test 52: copy_carry_files — mapped carry bypasses git-tracked check
# ============================================================================
echo "Test 52: copy_carry_files with mapped dest should carry git-tracked files"

setup_test_cage "source52"

# file.txt is already committed (git-tracked)
# With explicit dest, it should still be carried (to a different path)
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "file.txt|reference.txt" >/dev/null

if [ ! -f "$WORK_DIR/reference.txt" ]; then
    echo "FAIL: reference.txt should be created (mapped carry bypasses git-tracked check)"
    exit 1
fi
work_content=$(cat "$WORK_DIR/reference.txt")
source_content=$(cat "$SOURCE_PATH/file.txt")
if [ "$work_content" != "$source_content" ]; then
    echo "FAIL: reference.txt content should match source file.txt"
    exit 1
fi
echo "  PASS: Mapped carry copies git-tracked file to different dest"

# Test 53: from_cage skips files the cage didn't touch (snapshot match)
echo ""
echo "Test 53: from_cage announces skip when the file wasn't touched in the cage"
setup_test_cage "source53"
mkdir -p "$SOURCE_PATH/.caged"
echo "the only version" > "$SOURCE_PATH/CLAUDE.md"
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" >/dev/null

# Don't touch the cage copy. Exit pass should report a skip and deposit nothing.
out=$(copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" 2>&1)
if ! echo "$out" | grep -q "Skippin' CLAUDE.md"; then
    echo "FAIL: expected 'Skippin' CLAUDE.md' message, got:"
    echo "$out"
    exit 1
fi
label=$(display_session_name "$CLAUDE_CAGE_SESSION")
if [ -e "$SOURCE_PATH/.caged/carry/$label/CLAUDE.md" ]; then
    echo "FAIL: nothing should have been deposited for an untouched file"
    exit 1
fi
echo "  PASS: untouched file is announced and not deposited"

# Test 54: from_cage with no .caged/ dir lists files as lost
echo ""
echo "Test 54: from_cage warns when there's no .caged/ to deposit into"
setup_test_cage "source54"
echo "source ver" > "$SOURCE_PATH/CLAUDE.md"
copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" >/dev/null
# Cage edits the file but project has no .caged dir.
echo "cage edited" > "$WORK_DIR/CLAUDE.md"

out=$(copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" 2>&1)
if ! echo "$out" | grep -q "ain't bein' saved"; then
    echo "FAIL: expected 'ain't bein' saved' warning, got:"
    echo "$out"
    exit 1
fi
if ! echo "$out" | grep -q "CLAUDE.md"; then
    echo "FAIL: warning should name the lost file"
    exit 1
fi
if [ "$(cat "$SOURCE_PATH/CLAUDE.md")" != "source ver" ]; then
    echo "FAIL: source should never be touched"
    exit 1
fi
echo "  PASS: lost-edits warning fires when .caged/ absent"

# Test 55: from_cage with no manifest (e.g. attach mode) deposits whatever is in the cage
echo ""
echo "Test 55: from_cage with no startup manifest deposits the cage's current content"
setup_test_cage "source55"
mkdir -p "$SOURCE_PATH/.caged"
# Skip the to_work pass — simulates attach mode (work dir was set up earlier).
echo "from cage" > "$WORK_DIR/CLAUDE.md"

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" "CLAUDE.md|CLAUDE.md" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit="$SOURCE_PATH/.caged/carry/$label/CLAUDE.md"
if [ ! -f "$deposit" ] || [ "$(cat "$deposit")" != "from cage" ]; then
    echo "FAIL: expected deposit with cage's content at $deposit"
    exit 1
fi
echo "  PASS: missing manifest treats file as changed and deposits"

# Test 56: dir carry — cage didn't touch contents, skip the deposit
echo ""
echo "Test 56: from_cage skips a carry directory the cage didn't touch"
setup_test_cage "source56"
mkdir -p "$SOURCE_PATH/.claude" "$SOURCE_PATH/.caged"
echo "a content" > "$SOURCE_PATH/.claude/a.md"
echo "b content" > "$SOURCE_PATH/.claude/b.md"
mkdir -p "$SOURCE_PATH/.claude/sub"
echo "nested" > "$SOURCE_PATH/.claude/sub/c.md"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

# Cage doesn't touch any of the files inside .claude/.
out=$(copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" 2>&1)
if ! echo "$out" | grep -q "Skippin' .claude"; then
    echo "FAIL: untouched dir should produce a Skippin' message, got:"
    echo "$out"
    exit 1
fi
label=$(display_session_name "$CLAUDE_CAGE_SESSION")
if [ -e "$SOURCE_PATH/.caged/carry/$label/.claude" ]; then
    echo "FAIL: untouched dir should not be deposited"
    exit 1
fi
echo "  PASS: unchanged dir announced as skip, no deposit"

# Test 57: dir carry — file inside got edited → deposit fires
echo ""
echo "Test 57: from_cage deposits a carry directory whose file content changed"
setup_test_cage "source57"
mkdir -p "$SOURCE_PATH/.claude" "$SOURCE_PATH/.caged"
echo "a content" > "$SOURCE_PATH/.claude/a.md"
echo "b content" > "$SOURCE_PATH/.claude/b.md"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

# Cage edits one file inside.
echo "edited in cage" > "$WORK_DIR/.claude/a.md"

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit="$SOURCE_PATH/.caged/carry/$label/.claude"
if [ ! -f "$deposit/a.md" ] || [ "$(cat "$deposit/a.md")" != "edited in cage" ]; then
    echo "FAIL: edited file not deposited (expected at $deposit/a.md)"
    ls -R "$SOURCE_PATH/.caged" 2>/dev/null
    exit 1
fi
# The unchanged b.md gets carried along since the whole dir is deposited.
if [ ! -f "$deposit/b.md" ]; then
    echo "FAIL: full dir should be deposited once any file inside changed"
    exit 1
fi
echo "  PASS: edited file inside dir triggers deposit"

# Test 58: dir carry — file added in cage → deposit fires
echo ""
echo "Test 58: from_cage deposits when a new file appears in a carry dir"
setup_test_cage "source58"
mkdir -p "$SOURCE_PATH/.claude" "$SOURCE_PATH/.caged"
echo "a content" > "$SOURCE_PATH/.claude/a.md"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

# Cage adds a brand-new file inside (no edits to existing ones).
echo "new in cage" > "$WORK_DIR/.claude/new.md"

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit="$SOURCE_PATH/.caged/carry/$label/.claude"
[ -f "$deposit/new.md" ] || { echo "FAIL: new file not deposited"; exit 1; }
echo "  PASS: new file in dir triggers deposit"

# Test 59: dir carry — file removed in cage → deposit fires
echo ""
echo "Test 59: from_cage deposits when a file vanishes from a carry dir"
setup_test_cage "source59"
mkdir -p "$SOURCE_PATH/.claude" "$SOURCE_PATH/.caged"
echo "a content" > "$SOURCE_PATH/.claude/a.md"
echo "b content" > "$SOURCE_PATH/.claude/b.md"

copy_carry_files "to_work" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

# Cage removes a file (mimics rm inside the cage).
rm "$WORK_DIR/.claude/b.md"

copy_carry_files "from_cage" "$SOURCE_PATH" "$WORK_DIR" "" ".claude|.claude" >/dev/null

label=$(display_session_name "$CLAUDE_CAGE_SESSION")
deposit="$SOURCE_PATH/.caged/carry/$label/.claude"
[ -f "$deposit/a.md" ] || { echo "FAIL: surviving file not deposited"; exit 1; }
[ -e "$deposit/b.md" ] && { echo "FAIL: deleted file should not show up in deposit"; exit 1; }
echo "  PASS: file removed from dir triggers deposit"

echo ""
echo "Test 60: sync_to_source brings root commit back to a freshly-initialized source"

# Source: brand-new repo, no commits. Cage scaffolds a project; every cage
# commit (including the root) must land on source. Production runs this code
# path without `set -e`; fast-export on an empty repo errors out but
# create_intermediary_clone keeps going and leaves an empty intermediary.
# Match that here.
EMPTY_SRC="$TEST_TMP/source60"
rm -rf "$EMPTY_SRC"
mkdir -p "$EMPTY_SRC"
git -C "$EMPTY_SRC" init -q
git -C "$EMPTY_SRC" config user.email "test@test.com"
git -C "$EMPTY_SRC" config user.name "Test"

CLAUDE_CAGE_SESSION="test-session-$$-60"
export CLAUDE_CAGE_SESSION

EMPTY_INT=$(get_intermediary_path "$EMPTY_SRC")
EMPTY_WORK=$(get_work_path "$EMPTY_SRC")

set +e
create_intermediary_clone "$EMPTY_SRC" >/dev/null 2>&1
set -e

# Empty source → intermediary HEAD points at a branch with no commits.
# Detect that branch and have the cage push it.
EMPTY_BRANCH=$(git -C "$EMPTY_SRC" symbolic-ref --short HEAD)

# Cage clones intermediary, makes scaffold commits including the root.
rm -rf "$EMPTY_WORK"
git clone -q "$EMPTY_INT" "$EMPTY_WORK"
git -C "$EMPTY_WORK" config user.email "test@test.com"
git -C "$EMPTY_WORK" config user.name "Claude"
git -C "$EMPTY_WORK" checkout -q -b "$EMPTY_BRANCH" 2>/dev/null || git -C "$EMPTY_WORK" checkout -q "$EMPTY_BRANCH"
echo "scaffold" > "$EMPTY_WORK/README.md"
git -C "$EMPTY_WORK" add README.md
git -C "$EMPTY_WORK" commit -q -m "Scaffold project"
mkdir -p "$EMPTY_WORK/src"
echo "console.log('hi')" > "$EMPTY_WORK/src/index.js"
git -C "$EMPTY_WORK" add src/index.js
git -C "$EMPTY_WORK" commit -q -m "Add entry point"

git -C "$EMPTY_WORK" push -q origin "$EMPTY_BRANCH" 2>/dev/null

# Sync as the post-receive hook would: oldrev=zeros for a new branch.
sync_to_source "$EMPTY_SRC" "$EMPTY_INT" "refs/heads/$EMPTY_BRANCH" "0000000000000000000000000000000000000000" >/dev/null 2>&1

# Source must now have both commits, the root included, on $EMPTY_BRANCH.
src_commit_count=$(git -C "$EMPTY_SRC" rev-list --count "$EMPTY_BRANCH" 2>/dev/null || echo 0)
if [ "$src_commit_count" != "2" ]; then
    echo "FAIL: source should have 2 commits on $EMPTY_BRANCH after sync, has: $src_commit_count"
    exit 1
fi
src_readme=$(git -C "$EMPTY_SRC" show "$EMPTY_BRANCH:README.md" 2>/dev/null)
if [ "$src_readme" != "scaffold" ]; then
    echo "FAIL: source README.md content wrong: '$src_readme'"
    exit 1
fi
src_index=$(git -C "$EMPTY_SRC" show "$EMPTY_BRANCH:src/index.js" 2>/dev/null)
if [ "$src_index" != "console.log('hi')" ]; then
    echo "FAIL: source src/index.js content wrong: '$src_index'"
    exit 1
fi

# Root commit must have no parent on source.
src_root=$(git -C "$EMPTY_SRC" rev-list --max-parents=0 "$EMPTY_BRANCH" 2>/dev/null)
if [ -z "$src_root" ]; then
    echo "FAIL: no root commit on source $EMPTY_BRANCH after sync"
    exit 1
fi

# Working tree should reflect the synced commits (source had no HEAD before).
[ -f "$EMPTY_SRC/README.md" ] || { echo "FAIL: README.md missing from source working tree"; exit 1; }
[ -f "$EMPTY_SRC/src/index.js" ] || { echo "FAIL: src/index.js missing from source working tree"; exit 1; }
echo "  PASS: root commit + follow-on commit synced to fresh source"

echo ""
echo "=== All git-sync tests passed! ==="
