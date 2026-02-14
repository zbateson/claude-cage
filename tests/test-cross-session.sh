#!/bin/bash
# Test cross-project session sharing
# Tests session-level PID registration, cross-project discovery,
# isolated session markers, and shared session lifecycle

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

OTHER_PIDS=()
cleanup() {
    for pid in "${OTHER_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing cross-project session sharing ==="
echo ""

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

dry_run=false
verbose=false

# Create two separate projects
mkdir -p "$TEST_TMP/project-a"
cd "$TEST_TMP/project-a"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "project A" > readme.txt
git add -A && git commit -q -m "Initial A"

mkdir -p "$TEST_TMP/project-b"
cd "$TEST_TMP/project-b"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "project B" > readme.txt
git add -A && git commit -q -m "Initial B"

PROJECT_A="$TEST_TMP/project-a"
PROJECT_B="$TEST_TMP/project-b"

# ============================================================================
echo "=== Testing session-level PID registration ==="
echo ""

echo "Test 1: Two PIDs for different source_dirs in same session"
CLAUDE_CAGE_SESSION="shared-session-1"
register_session "$PROJECT_A"

# Simulate another process for project B in the same session
sleep 300 &
other_pid=$!
OTHER_PIDS+=($other_pid)
session_dir=$(get_session_dir "shared-session-1")
echo "$PROJECT_B" > "$session_dir/$other_pid"

# Both files should exist
if [ ! -f "$session_dir/$$" ]; then
    echo "FAIL: PID file for project A should exist"
    exit 1
fi
if [ ! -f "$session_dir/$other_pid" ]; then
    echo "FAIL: PID file for project B should exist"
    exit 1
fi
# Content should be source_dirs
file_a=$(cat "$session_dir/$$")
file_b=$(cat "$session_dir/$other_pid")
if [ "$file_a" != "$PROJECT_A" ]; then
    echo "FAIL: PID file content should be source_dir ($PROJECT_A), got '$file_a'"
    exit 1
fi
if [ "$file_b" != "$PROJECT_B" ]; then
    echo "FAIL: PID file content should be source_dir ($PROJECT_B), got '$file_b'"
    exit 1
fi
echo "  PASS: Two PIDs in same session dir with correct source_dir content"

# ============================================================================
echo ""
echo "Test 2: session_is_active(session_id) finds any live PID"
if ! session_is_active "shared-session-1"; then
    echo "FAIL: session_is_active should return true"
    exit 1
fi
echo "  PASS: session_is_active detects live PID"

# ============================================================================
echo "Test 3: session_is_active returns false for dead session"
if session_is_active "nonexistent-session"; then
    echo "FAIL: session_is_active should return false for nonexistent session"
    exit 1
fi
echo "  PASS: session_is_active returns false for nonexistent session"

# ============================================================================
echo "Test 4: session_is_active_for_source checks source_dir match"
if ! session_is_active_for_source "shared-session-1" "$PROJECT_A"; then
    echo "FAIL: session_is_active_for_source should return true for project A"
    exit 1
fi
if ! session_is_active_for_source "shared-session-1" "$PROJECT_B"; then
    echo "FAIL: session_is_active_for_source should return true for project B"
    exit 1
fi
# Non-registered source should return false
if session_is_active_for_source "shared-session-1" "/nonexistent"; then
    echo "FAIL: session_is_active_for_source should return false for unregistered source"
    exit 1
fi
echo "  PASS: session_is_active_for_source checks source_dir correctly"

# ============================================================================
echo "Test 5: has_other_sessions scans all session dirs"
# Project A has our PID in shared-session-1 — but also the other PID is for project B, not A.
# So for project A, has_other_sessions should return false (only our PID matches project A)
if has_other_sessions "$PROJECT_A"; then
    echo "FAIL: has_other_sessions should return false (only our own PID matches project A)"
    exit 1
fi
# For project B, has_other_sessions from our perspective ($$) should find the sleep process
if ! has_other_sessions "$PROJECT_B"; then
    echo "FAIL: has_other_sessions should return true for project B (other PID exists)"
    exit 1
fi
echo "  PASS: has_other_sessions scans all session dirs correctly"

# ============================================================================
echo "Test 6: has_any_sessions finds sessions across session dirs"
if ! has_any_sessions "$PROJECT_A"; then
    echo "FAIL: has_any_sessions should return true for project A (our PID)"
    exit 1
fi
if ! has_any_sessions "$PROJECT_B"; then
    echo "FAIL: has_any_sessions should return true for project B (other PID)"
    exit 1
fi
if has_any_sessions "/no-such-project"; then
    echo "FAIL: has_any_sessions should return false for unregistered project"
    exit 1
fi
echo "  PASS: has_any_sessions works across session dirs"

# Clean up registration
unregister_session "$PROJECT_A"
kill "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true

# ============================================================================
echo ""
echo "=== Testing isolated session markers ==="
echo ""

echo "Test 7: mark_session_isolated writes marker file"
mark_session_isolated "iso-session-1" "$PROJECT_A"
if [ ! -f "$CLAUDE_CAGE_CACHE/sessions/iso-session-1/.claude-cage-isolated" ]; then
    echo "FAIL: Isolated marker file should exist"
    exit 1
fi
echo "  PASS: Isolated marker file created"

echo "Test 8: is_session_isolated detects marker"
if ! is_session_isolated "iso-session-1"; then
    echo "FAIL: is_session_isolated should return true"
    exit 1
fi
if is_session_isolated "non-iso-session"; then
    echo "FAIL: is_session_isolated should return false for unmarked session"
    exit 1
fi
echo "  PASS: is_session_isolated detects marker correctly"

echo "Test 9: get_isolated_session_source reads source_dir"
iso_source=$(get_isolated_session_source "iso-session-1")
if [ "$iso_source" != "$PROJECT_A" ]; then
    echo "FAIL: Expected '$PROJECT_A', got '$iso_source'"
    exit 1
fi
echo "  PASS: get_isolated_session_source returns correct source_dir"

# ============================================================================
echo ""
echo "=== Testing cross-project session discovery ==="
echo ""

# Clean up
rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

# Create intermediaries for both projects
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
cfg_isolated=""

echo "Test 10: find_reusable_session discovers clean session from other project"
# Create a clean work dir for project A in a session
OLD_SID="2025-06-01_10-00-00"
mkdir -p "$CLAUDE_CAGE_CACHE/sessions/$OLD_SID/work$PROJECT_A"
git clone -q "$PROJECT_A" "$CLAUDE_CAGE_CACHE/sessions/$OLD_SID/work$PROJECT_A" 2>/dev/null || \
    (cd "$CLAUDE_CAGE_CACHE/sessions/$OLD_SID/work$PROJECT_A" && git init -q && echo "A" > readme.txt && git add -A && git commit -q -m "init")

# Now search from project B's perspective with isolated=false
cfg_isolated=""
find_reusable_session "$PROJECT_B"

# With non-isolated mode, the clean session for A should be found as a reusable session
# (it won't have a work dir for B, but it's still a clean session we can reuse)
if [ -z "$REUSE_CLEAN_SESSIONS" ]; then
    echo "FAIL: Should find clean session from project A"
    exit 1
fi
if [ "$REUSE_SESSION_STATE" != "clean" ]; then
    echo "FAIL: Expected state 'clean', got '$REUSE_SESSION_STATE'"
    exit 1
fi
echo "  PASS: Non-isolated find_reusable_session discovers cross-project clean session"

echo "Test 11: find_reusable_session skips isolated sessions from other projects"
# Mark the session as isolated for project A
mark_session_isolated "$OLD_SID" "$PROJECT_A"

# Search again — should skip because it's isolated for a different source
find_reusable_session "$PROJECT_B"
if [ "$REUSE_SESSION_STATE" != "none" ]; then
    echo "FAIL: Should skip isolated session from different project, got state '$REUSE_SESSION_STATE'"
    exit 1
fi
echo "  PASS: Isolated session from other project skipped"

# Clean up isolated marker for further tests
rm -f "$CLAUDE_CAGE_CACHE/sessions/$OLD_SID/.claude-cage-isolated"

echo "Test 12: reuse_or_create_session reuses cross-project clean session (non-isolated)"
cfg_isolated=""
REUSE_CLEAN_SESSIONS="$OLD_SID master $PROJECT_A "
reuse_or_create_session "$PROJECT_B" >/dev/null
# Session should be reused and renamed
if [ "$CLAUDE_CAGE_SESSION" = "$OLD_SID" ]; then
    echo "FAIL: Session should be renamed to new timestamp"
    exit 1
fi
if [ -d "$CLAUDE_CAGE_CACHE/sessions/$OLD_SID" ]; then
    echo "FAIL: Old session dir should be renamed away"
    exit 1
fi
if [ ! -d "$CLAUDE_CAGE_CACHE/sessions/$CLAUDE_CAGE_SESSION" ]; then
    echo "FAIL: New session dir should exist"
    exit 1
fi
echo "  PASS: Cross-project clean session reused (non-isolated)"

# ============================================================================
echo ""
echo "=== Testing joinable active sessions ==="
echo ""

rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

echo "Test 13: Active session is joinable when not isolated"
# Create session and register a live PID for project A
ACTIVE_SID="2025-07-01_10-00-00"
mkdir -p "$CLAUDE_CAGE_CACHE/sessions/$ACTIVE_SID/work$PROJECT_A"
git clone -q "$PROJECT_A" "$CLAUDE_CAGE_CACHE/sessions/$ACTIVE_SID/work$PROJECT_A" 2>/dev/null || \
    (cd "$CLAUDE_CAGE_CACHE/sessions/$ACTIVE_SID/work$PROJECT_A" && git init -q && echo "A" > readme.txt && git add -A && git commit -q -m "init")

sleep 300 &
active_pid=$!
OTHER_PIDS+=($active_pid)
active_session_dir=$(get_session_dir "$ACTIVE_SID")
mkdir -p "$active_session_dir"
echo "$PROJECT_A" > "$active_session_dir/$active_pid"

# From project B's perspective, this should be joinable
cfg_isolated=""
find_reusable_session "$PROJECT_B"

if [ -z "$REUSE_JOINABLE_SESSIONS" ]; then
    echo "FAIL: Active session should be joinable for non-isolated project B"
    exit 1
fi
joinable_id=$(echo "$REUSE_JOINABLE_SESSIONS" | head -1)
if [ "$joinable_id" != "$ACTIVE_SID" ]; then
    echo "FAIL: Expected joinable session '$ACTIVE_SID', got '$joinable_id'"
    exit 1
fi
echo "  PASS: Active session listed as joinable"

echo "Test 14: reuse_or_create_session joins active session (non-isolated)"
REUSE_JOINABLE_SESSIONS="$ACTIVE_SID"
REUSE_CLEAN_SESSIONS=""
reuse_or_create_session "$PROJECT_B" >/dev/null
if [ "$CLAUDE_CAGE_SESSION" != "$ACTIVE_SID" ]; then
    echo "FAIL: Should join active session $ACTIVE_SID, got $CLAUDE_CAGE_SESSION"
    exit 1
fi
echo "  PASS: Joined active session"

echo "Test 15: Isolated project does NOT join shared active sessions"
cfg_isolated="true"
REUSE_JOINABLE_SESSIONS=""
REUSE_CLEAN_SESSIONS=""
find_reusable_session "$PROJECT_B"
if [ -n "$REUSE_JOINABLE_SESSIONS" ]; then
    echo "FAIL: Isolated project should not have joinable sessions"
    exit 1
fi
echo "  PASS: Isolated project cannot join shared sessions"

# Clean up
kill "$active_pid" 2>/dev/null || true
wait "$active_pid" 2>/dev/null || true
cfg_isolated=""

# ============================================================================
echo ""
echo "=== Testing enumerate_projects with cross-project work dirs ==="
echo ""

rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

echo "Test 16: enumerate_projects discovers two work dirs in same session"
# Set up intermediaries
IDIR_A="$CLAUDE_CAGE_CACHE/intermediary$PROJECT_A"
IDIR_B="$CLAUDE_CAGE_CACHE/intermediary$PROJECT_B"
mkdir -p "$(dirname "$IDIR_A")" "$(dirname "$IDIR_B")"
git init --bare "$IDIR_A" -q
git init --bare "$IDIR_B" -q
git -C "$PROJECT_A" fast-export HEAD 2>/dev/null | git -C "$IDIR_A" fast-import --quiet 2>/dev/null
git -C "$PROJECT_B" fast-export HEAD 2>/dev/null | git -C "$IDIR_B" fast-import --quiet 2>/dev/null

# Store git-root metadata (needed for scope-aware mount logic)
echo "$PROJECT_A" > "$IDIR_A/claude-cage-git-root"
echo "" > "$IDIR_A/claude-cage-scope-path"
echo "$PROJECT_B" > "$IDIR_B/claude-cage-git-root"
echo "" > "$IDIR_B/claude-cage-scope-path"

# Create work dirs in same session
CROSS_SID="cross-enum-session"
CLAUDE_CAGE_SESSION="$CROSS_SID"
SWR="$CLAUDE_CAGE_CACHE/sessions/$CROSS_SID/work"
WORK_A="$SWR$PROJECT_A"
WORK_B="$SWR$PROJECT_B"
mkdir -p "$WORK_A" "$WORK_B"
git clone -q "$IDIR_A" "$WORK_A"
git clone -q "$IDIR_B" "$WORK_B"
# Set remote URL to /run<intermediary_path> (as the cage does)
git -C "$WORK_A" remote set-url origin "/run$IDIR_A"
git -C "$WORK_B" remote set-url origin "/run$IDIR_B"

cfg_isolated=""
enumerate_projects "$SWR" "$CLAUDE_CAGE_CACHE/intermediary" "$WORK_A" "$IDIR_A" "$PROJECT_A"

# Should have 2 work projects (project A + project B)
if [ ${#CAGE_WORK_PROJECTS[@]} -ne 2 ]; then
    echo "FAIL: Expected 2 work projects, got ${#CAGE_WORK_PROJECTS[@]}"
    for e in "${CAGE_WORK_PROJECTS[@]}"; do echo "  $e"; done
    exit 1
fi
echo "  PASS: enumerate_projects found 2 work dirs in session"

echo "Test 17: enumerate_projects includes intermediary for discovered project"
if [ ${#CAGE_INTERMEDIARY_PROJECTS[@]} -lt 2 ]; then
    echo "FAIL: Expected at least 2 intermediary projects, got ${#CAGE_INTERMEDIARY_PROJECTS[@]}"
    for e in "${CAGE_INTERMEDIARY_PROJECTS[@]}"; do echo "  $e"; done
    exit 1
fi
echo "  PASS: Both intermediaries discovered"

echo "Test 18: enumerate_projects returns empty for isolated mode"
cfg_isolated="true"
enumerate_projects "$SWR" "$CLAUDE_CAGE_CACHE/intermediary" "$WORK_A" "$IDIR_A" "$PROJECT_A"
if [ ${#CAGE_WORK_PROJECTS[@]} -ne 0 ]; then
    echo "FAIL: Isolated mode should return empty arrays, got ${#CAGE_WORK_PROJECTS[@]} work projects"
    exit 1
fi
echo "  PASS: Isolated mode returns empty"
cfg_isolated=""

# ============================================================================
echo ""
echo "=== Testing shared session cleanup ==="
echo ""

rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

echo "Test 19: clean_session_cache removes only target project's work dir"
# Set up a shared session with two projects
CLEAN_SID="cleanup-test-session"
CLAUDE_CAGE_SESSION="$CLEAN_SID"
CLEAN_SWR="$CLAUDE_CAGE_CACHE/sessions/$CLEAN_SID/work"
CLEAN_WORK_A="$CLEAN_SWR$PROJECT_A"
CLEAN_WORK_B="$CLEAN_SWR$PROJECT_B"
mkdir -p "$CLEAN_WORK_A" "$CLEAN_WORK_B"
git clone -q "$IDIR_A" "$CLEAN_WORK_A"
git clone -q "$IDIR_B" "$CLEAN_WORK_B"

clean_session_cache "$PROJECT_A" "$CLEAN_SID"

if [ -d "$CLEAN_WORK_A" ]; then
    echo "FAIL: Project A work dir should be removed"
    exit 1
fi
if [ ! -d "$CLEAN_WORK_B/.git" ]; then
    echo "FAIL: Project B work dir should still exist"
    exit 1
fi
echo "  PASS: Only project A's work dir removed from shared session"

echo "Test 20: Session dir persists while other project's work dir remains"
session_cache="$CLAUDE_CAGE_CACHE/sessions/$CLEAN_SID"
if [ ! -d "$session_cache" ]; then
    echo "FAIL: Session dir should persist (project B work dir remains)"
    exit 1
fi
echo "  PASS: Session dir persists"

echo "Test 21: Session dir removed after all work dirs cleaned"
clean_session_cache "$PROJECT_B" "$CLEAN_SID"
if [ -d "$session_cache" ]; then
    echo "FAIL: Session dir should be removed when all work dirs cleaned"
    exit 1
fi
echo "  PASS: Session dir removed when empty"

echo ""
echo "=== All cross-session tests passed! ==="
