#!/bin/bash
# Test cross-project session sharing
# Tests session-level PID registration, enumerate_projects for
# cross-project mounting, and shared-session cleanup.

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
echo "=== Testing enumerate_projects with cross-project work dirs ==="
echo ""

rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

# Create intermediaries for both projects
cfg_exclude=""
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"

echo "Test 17: enumerate_projects discovers two work dirs in same session"
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

echo "Test 18: enumerate_projects includes intermediary for discovered project"
if [ ${#CAGE_INTERMEDIARY_PROJECTS[@]} -lt 2 ]; then
    echo "FAIL: Expected at least 2 intermediary projects, got ${#CAGE_INTERMEDIARY_PROJECTS[@]}"
    for e in "${CAGE_INTERMEDIARY_PROJECTS[@]}"; do echo "  $e"; done
    exit 1
fi
echo "  PASS: Both intermediaries discovered"

# ============================================================================
echo ""
echo "=== Testing shared session cleanup ==="
echo ""

rm -rf "$CLAUDE_CAGE_CACHE/sessions" "$CLAUDE_CAGE_RUNTIME/sessions"

echo "Test 20: clean_session_cache removes only target project's work dir"
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

echo "Test 21: Session dir persists while other project's work dir remains"
session_cache="$CLAUDE_CAGE_CACHE/sessions/$CLEAN_SID"
if [ ! -d "$session_cache" ]; then
    echo "FAIL: Session dir should persist (project B work dir remains)"
    exit 1
fi
echo "  PASS: Session dir persists"

echo "Test 22: Session dir removed after all work dirs cleaned"
clean_session_cache "$PROJECT_B" "$CLEAN_SID"
if [ -d "$session_cache" ]; then
    echo "FAIL: Session dir should be removed when all work dirs cleaned"
    exit 1
fi
echo "  PASS: Session dir removed when empty"

echo ""
echo "=== All cross-session tests passed! ==="
