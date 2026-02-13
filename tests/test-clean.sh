#!/bin/bash
# Test clean and clean-all commands
# Tests cache cleanup functionality for session-based architecture:
#   - Intermediary is a bare repo shared across sessions at $CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH
#   - Work dirs are per-session at $CLAUDE_CAGE_CACHE/sessions/$SESSION/work$SOURCE_PATH
#   - clean_session_cache removes work dir, post-commit hook, and shared intermediary only if no other sessions remain

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
    kill $OTHER_PID 2>/dev/null || true
    rm -rf "$TEST_TMP"
}
OTHER_PID=""
trap cleanup EXIT

echo "=== Testing clean commands ==="
echo ""

# Create a minimal test setup
mkdir -p "$TEST_TMP/source"
cd "$TEST_TMP/source"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
git add .
git commit -q -m "Initial"

cat > "$TEST_TMP/source/.claude-cage" << 'EOF'
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    autoSync = true
}
EOF

# Compute expected paths for new architecture
SOURCE_PATH="$TEST_TMP/source"
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
# Intermediary is shared across branches (not per-branch)
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH"
SESSION_ID="" # Will be populated after cage creation
WORK_DIR="" # Will be populated after cage creation
# Only post-commit hook exists (no pre-commit in new architecture)
HOOK_PATH_HASH=$(echo -n "$SOURCE_PATH" | md5sum | cut -c1-12)
POST_COMMIT_HOOK="$SOURCE_PATH/.git/hooks/post-commit.d/claude-cage-$HOOK_PATH_HASH"

echo "=== Setting up test cage ==="

echo "Test 1: Create cage to have something to clean"
cd "$TEST_TMP/source"
# Use env -i for consistent behavior across different shell environments
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

# Discover the session ID from the created session directory
SESSION_ID=$(ls -1 "$CLAUDE_CAGE_CACHE/sessions/" 2>/dev/null | head -1)
WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$SESSION_ID/work$SOURCE_PATH"

if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should exist after cage creation"
    exit 1
fi
echo "  PASS: Cage created successfully"

echo "Test 2: Simulate orphaned post-commit hook (as if session crashed)"
# Normal exit cleans up hooks, so we manually create them to simulate a crash
mkdir -p "$SOURCE_PATH/.git/hooks/post-commit.d"

cat > "$SOURCE_PATH/.git/hooks/post-commit" << 'DISPATCHER'
#!/bin/bash
# claude-cage-dispatcher
HOOK_DIR="$(dirname "$0")/$(basename "$0").d"
[ -d "$HOOK_DIR" ] && for hook in "$HOOK_DIR"/*; do [ -x "$hook" ] && "$hook" "$@"; done
DISPATCHER
chmod +x "$SOURCE_PATH/.git/hooks/post-commit"

cat > "$POST_COMMIT_HOOK" << EOF
#!/bin/bash
INTERMEDIARY="$INTERMEDIARY_DIR"
EOF
chmod +x "$POST_COMMIT_HOOK"

if [ ! -f "$POST_COMMIT_HOOK" ]; then
    echo "FAIL: Failed to create simulated orphaned post-commit hook"
    exit 1
fi
echo "  PASS: Simulated orphaned post-commit hook created"

echo ""
echo "=== Testing clean with session ID ==="

echo "Test 3: clean with nonexistent session should fail"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" clean nonexistent 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q "not found"; then
    echo "FAIL: Should report session not found"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports nonexistent session correctly"

echo "Test 4: clean <id> should remove specified session work dir"
# Answer 'y' to confirmation prompt
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "y" | "$2" clean "'"$SESSION_ID"'" >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should be removed after clean"
    exit 1
fi
echo "  PASS: Session work dir removed successfully"

echo "Test 5: clean should also remove post-commit hook"
if [ -f "$POST_COMMIT_HOOK" ]; then
    echo "FAIL: post-commit hook should be removed after clean"
    exit 1
fi
echo "  PASS: Post-commit hook removed"

echo ""
echo "=== Testing shared intermediary lifecycle ==="

echo "Test 6: Shared intermediary preserved when other sessions still have work dirs"
# Recreate cage for main branch first
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

SESSION_ID=$(ls -1 "$CLAUDE_CAGE_CACHE/sessions/" 2>/dev/null | head -1)
WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$SESSION_ID/work$SOURCE_PATH"

# Simulate a second session's work directory (as if cage was started in another session)
FEATURE_SESSION_ID="2025-01-01_12-00-00"
FEATURE_WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$FEATURE_SESSION_ID/work$SOURCE_PATH"
mkdir -p "$FEATURE_WORK_DIR/.git"

# Verify both exist before cleaning
if [ ! -d "$WORK_DIR" ] || [ ! -d "$FEATURE_WORK_DIR" ]; then
    echo "FAIL: Both session work dirs should exist before test"
    exit 1
fi

# Clean main session - intermediary should survive because feature session's work dir still exists
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "y" | "$2" clean "'"$SESSION_ID"'" >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ ! -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Shared intermediary should still exist when other sessions have work dirs"
    exit 1
fi
echo "  PASS: Shared intermediary preserved when other sessions exist"

echo "Test 7: Shared intermediary removed when ALL sessions cleaned"
# Now clean the feature session too - use the function directly via sourcing
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

CLAUDE_CAGE_SESSION="$FEATURE_SESSION_ID"
export CLAUDE_CAGE_SESSION
dry_run=false
verbose=false

clean_session_cache "$SOURCE_PATH" "$FEATURE_SESSION_ID"

if [ -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Shared intermediary should be removed when no sessions have work dirs"
    exit 1
fi
echo "  PASS: Shared intermediary removed when all sessions cleaned"

echo ""
echo "=== Testing clean --all ==="

echo "Test 8: clean --all should remove all caches"
# Recreate cage
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

SESSION_ID=$(ls -1 "$CLAUDE_CAGE_CACHE/sessions/" 2>/dev/null | head -1)
WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$SESSION_ID/work$SOURCE_PATH"

if [ ! -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should exist after cage recreation"
    exit 1
fi

# Answer 'y' to confirmation
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "y" | "$2" clean --all >/dev/null 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage"

if [ -d "$WORK_DIR" ]; then
    echo "FAIL: Work directory should be removed after clean --all"
    exit 1
fi
if [ -d "$INTERMEDIARY_DIR" ]; then
    echo "FAIL: Shared intermediary should be removed after clean --all"
    exit 1
fi
echo "  PASS: All caches removed"

echo ""
echo "=== Testing clean with no caches ==="

echo "Test 9: clean with no caches should report nothing to clean"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && "$2" clean 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "nothin"; then
    echo "FAIL: Should report nothing to clean"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Reports no caches correctly"

echo ""
echo "=== Testing dirty work directory warnings ==="

echo "Test 10: clean should show warning for dirty session"
# Recreate cage and make it dirty
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

SESSION_ID=$(ls -1 "$CLAUDE_CAGE_CACHE/sessions/" 2>/dev/null | head -1)
WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/$SESSION_ID/work$SOURCE_PATH"

# Make the work directory dirty
echo "dirty change" >> "$WORK_DIR/file.txt"

# Don't actually clean, just check the output shows warning
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "n" | "$2" clean "'"$SESSION_ID"'" 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "uncommitted"; then
    echo "FAIL: Should warn about uncommitted changes"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: Shows uncommitted changes warning"

echo "Test 11: clean --all should show warning for dirty session"
output=$(env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    bash -c 'cd "$1" && echo "n" | "$2" clean --all 2>&1' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage") || true

if ! echo "$output" | grep -q -i "uncommitted"; then
    echo "FAIL: Should warn about uncommitted changes in branch list"
    echo "Output was:"
    echo "$output"
    exit 1
fi
echo "  PASS: clean --all shows dirty warning"

echo ""
echo "=== Testing rename on reuse ==="
echo ""

# Clean up for a fresh start
rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_CACHE/intermediary" "$CLAUDE_CAGE_CACHE/scoped"

# Re-source to get fresh function definitions
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING
dry_run=false
verbose=false

echo "Test 12: Rename on reuse gives session a fresh timestamp"
# Create a session with an old-format ID to simulate an existing inactive clean session
OLD_SID="2024-06-15_08-30-00"
OLD_SESSION_DIR="$CLAUDE_CAGE_CACHE/sessions/$OLD_SID"
mkdir -p "$OLD_SESSION_DIR/work$SOURCE_PATH"
# Clone the intermediary into the old work dir so it looks like a real session
env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
    CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
    GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
    GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
    bash -c 'cd "$1" && echo "exit" | "$2" --test' _ "$TEST_TMP/source" "$CAGE_DIR/dist/claude-cage" >/dev/null 2>&1 || true

# Rebuild the intermediary so we have something to work with
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH"
if [ ! -d "$INTERMEDIARY_DIR" ]; then
    CLAUDE_CAGE_SESSION="$OLD_SID"
    create_intermediary_clone "$SOURCE_PATH" "" >/dev/null 2>&1
fi

# Make sure old session dir has a proper work dir (re-clone from intermediary)
rm -rf "$OLD_SESSION_DIR"
mkdir -p "$OLD_SESSION_DIR/work$SOURCE_PATH"
git clone -q "$INTERMEDIARY_DIR" "$OLD_SESSION_DIR/work$SOURCE_PATH"

# Set up REUSE_CLEAN_SESSIONS as find_reusable_session would
BRANCH_NAME=$(git -C "$SOURCE_PATH" branch --show-current)
REUSE_CLEAN_SESSIONS="$OLD_SID $BRANCH_NAME $SOURCE_PATH "

# Call reuse_or_create_session
reuse_or_create_session "$SOURCE_PATH" >/dev/null

# Verify old dir is gone
if [ -d "$OLD_SESSION_DIR" ]; then
    echo "FAIL: Old session dir should be renamed away"
    exit 1
fi

# Verify new session ID has the new date format (YYYY-MM-DD_HH-MM-SS)
if ! [[ "$CLAUDE_CAGE_SESSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "FAIL: New session ID '$CLAUDE_CAGE_SESSION' doesn't match YYYY-MM-DD_HH-MM-SS format"
    exit 1
fi

# Verify new dir exists
NEW_SESSION_DIR="$CLAUDE_CAGE_CACHE/sessions/$CLAUDE_CAGE_SESSION"
if [ ! -d "$NEW_SESSION_DIR/work$SOURCE_PATH" ]; then
    echo "FAIL: Renamed session dir should exist at $NEW_SESSION_DIR"
    exit 1
fi
echo "  PASS: Session renamed from $OLD_SID to $CLAUDE_CAGE_SESSION"

echo ""
echo "=== Testing proactive exit cleanup ==="
echo ""

echo "Test 13: Clean session removed on exit when other sessions active"
# Clean up
rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

# Start a background process to act as "another session"
sleep 300 &
OTHER_PID=$!

# Create two session work dirs
SID_A="2025-01-01_10-00-00"
SID_B="2025-01-01_11-00-00"
WORK_A="$CLAUDE_CAGE_CACHE/sessions/$SID_A/work$SOURCE_PATH"
WORK_B="$CLAUDE_CAGE_CACHE/sessions/$SID_B/work$SOURCE_PATH"
mkdir -p "$WORK_A" "$WORK_B"
git clone -q "$INTERMEDIARY_DIR" "$WORK_A"
git clone -q "$INTERMEDIARY_DIR" "$WORK_B"

# Register session A as "us" (current PID)
CLAUDE_CAGE_SESSION="$SID_A"
register_session "$SOURCE_PATH"

# Register session B as the other live process
SESSION_DIR=$(get_session_dir "$SOURCE_PATH")
echo "$SID_B" > "$SESSION_DIR/$OTHER_PID"

# Verify has_other_sessions sees session B
if ! has_other_sessions "$SOURCE_PATH"; then
    kill $OTHER_PID 2>/dev/null || true
    echo "FAIL: Should detect other active session"
    exit 1
fi

# Simulate cleanup: unregister our session, then do the proactive cleanup logic
unregister_session "$SOURCE_PATH"

# Now the proactive cleanup check (mirrors cleanup_on_exit logic)
work_dir="$WORK_A"
if has_other_sessions "$SOURCE_PATH" && [ -d "$work_dir/.git" ] \
    && ! is_work_dirty "$work_dir" && ! work_has_unpushed "$work_dir"; then
    session_cache="$CLAUDE_CAGE_CACHE/sessions/$SID_A"
    rm -rf "$work_dir"
    cleanup_empty_parents "$work_dir" "$session_cache/work" "$session_cache"
    if [ -d "$session_cache/work" ] && [ -z "$(ls -A "$session_cache/work" 2>/dev/null)" ]; then
        rm -rf "$session_cache/work"
    fi
    if [ -d "$session_cache" ] && [ -z "$(ls -A "$session_cache" 2>/dev/null)" ]; then
        rm -rf "$session_cache"
    fi
fi

if [ -d "$WORK_A" ]; then
    kill $OTHER_PID 2>/dev/null || true
    echo "FAIL: Clean session work dir should be removed on exit"
    exit 1
fi
echo "  PASS: Clean session removed when other sessions active"

echo "Test 14: Dirty session kept on exit when other sessions active"
# Clean up
rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

# Create two sessions again
SID_C="2025-01-01_12-00-00"
SID_D="2025-01-01_13-00-00"
WORK_C="$CLAUDE_CAGE_CACHE/sessions/$SID_C/work$SOURCE_PATH"
WORK_D="$CLAUDE_CAGE_CACHE/sessions/$SID_D/work$SOURCE_PATH"
mkdir -p "$WORK_C" "$WORK_D"
git clone -q "$INTERMEDIARY_DIR" "$WORK_C"
git clone -q "$INTERMEDIARY_DIR" "$WORK_D"

# Make session C dirty
echo "dirty" >> "$WORK_C/file.txt"

# Register sessions
CLAUDE_CAGE_SESSION="$SID_C"
register_session "$SOURCE_PATH"
SESSION_DIR=$(get_session_dir "$SOURCE_PATH")
echo "$SID_D" > "$SESSION_DIR/$OTHER_PID"

# Unregister ours
unregister_session "$SOURCE_PATH"

# Proactive cleanup check — should NOT remove because dirty
work_dir="$WORK_C"
if has_other_sessions "$SOURCE_PATH" && [ -d "$work_dir/.git" ] \
    && ! is_work_dirty "$work_dir" && ! work_has_unpushed "$work_dir"; then
    rm -rf "$work_dir"
fi

if [ ! -d "$WORK_C" ]; then
    kill $OTHER_PID 2>/dev/null || true
    echo "FAIL: Dirty session should NOT be removed on exit"
    exit 1
fi
echo "  PASS: Dirty session kept on exit"

# Clean up background process and fake PID files
kill $OTHER_PID 2>/dev/null || true
rm -f "$SESSION_DIR/$OTHER_PID"

echo ""
echo "=== Testing scoped session cleanup ==="
echo ""

# Clean up any remaining sessions first
rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_CACHE/intermediary" "$CLAUDE_CAGE_CACHE/scoped"

# Re-source to get fresh function definitions
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING
dry_run=false
verbose=false

echo "Test 15: Scoped session shows scope in list_cached_sessions output"
# Create a monorepo structure
mkdir -p "$TEST_TMP/monorepo/services/api"
cd "$TEST_TMP/monorepo"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "root" > README.md
echo "api" > services/api/app.go
git add -A && git commit -q -m "Initial"

MONOREPO_PATH="$TEST_TMP/monorepo"
API_PATH="$MONOREPO_PATH/services/api"

# Create a scoped intermediary and session
CLAUDE_CAGE_SESSION="scoped-test-session"
export CLAUDE_CAGE_SESSION
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"

SCOPED_IDIR=$(get_scoped_intermediary_path "$API_PATH" "services/api")
create_intermediary_clone "$API_PATH" "services/api" >/dev/null 2>&1

# Write scope metadata into work dir
SCOPED_WORK=$(get_work_path "$API_PATH")

# Verify session listing from monorepo root
sessions=$(list_cached_sessions "$MONOREPO_PATH")
if ! echo "$sessions" | grep -q "services/api"; then
    echo "FAIL: list_cached_sessions should show scope for scoped session"
    echo "  Sessions:"
    echo "$sessions"
    exit 1
fi
echo "  PASS: Scoped session shows scope in listing"

echo "Test 16: Cross-scope session visible from git root"
if ! echo "$sessions" | grep -q "scoped-test-session"; then
    echo "FAIL: Scoped session not found when listing from git root"
    echo "  Sessions:"
    echo "$sessions"
    exit 1
fi
echo "  PASS: Cross-scope session visible from git root"

echo "Test 17: clean_session_cache for scoped session removes scoped/ when empty"
# Clean the scoped session
clean_session_cache "$API_PATH" "scoped-test-session"

if [ -d "$SCOPED_IDIR" ]; then
    echo "FAIL: Scoped intermediary should be removed after clean"
    exit 1
fi

# The scoped/ top-level dir should be removed when empty
if [ -d "$CLAUDE_CAGE_CACHE/scoped" ]; then
    if [ -n "$(ls -A "$CLAUDE_CAGE_CACHE/scoped" 2>/dev/null)" ]; then
        echo "FAIL: scoped/ dir should be empty or removed"
        ls -R "$CLAUDE_CAGE_CACHE/scoped"
        exit 1
    fi
    # It's empty but still exists — this is acceptable but we want it removed
    echo "FAIL: Empty scoped/ dir should be removed"
    exit 1
fi
echo "  PASS: scoped/ top-level dir cleaned up"

echo ""
echo "=== All clean tests passed! ==="
