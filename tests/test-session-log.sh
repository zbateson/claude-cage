#!/bin/bash
# Test per-session logging functionality
# Tests start_session_log, finalize_session_log, restore_original_fds,
# append_session_log, sync_log dual write, cleanup, and .caged symlink

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

echo "=== Testing session logging ==="
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
cfg_createCagedDir="true"
dry_run=false
verbose=false
debug=false

# ============================================================================
echo "Test 1: start_session_log creates temp log file with header"
# ============================================================================
start_session_log "$CLAUDE_CAGE_CACHE/logs"

if [ -z "$CLAUDE_CAGE_SESSION_LOG" ]; then
    echo "FAIL: CLAUDE_CAGE_SESSION_LOG should be set"
    exit 1
fi
if [ ! -f "$CLAUDE_CAGE_SESSION_LOG" ]; then
    echo "FAIL: Log file should exist at $CLAUDE_CAGE_SESSION_LOG"
    exit 1
fi
# Check temp file naming
case "$CLAUDE_CAGE_SESSION_LOG" in
    */.tmp-*.log) ;;
    *)
        echo "FAIL: Temp log should match .tmp-*.log pattern, got: $CLAUDE_CAGE_SESSION_LOG"
        exit 1
        ;;
esac
# Check header content
if ! grep -q "^=== claude-cage session log ===" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: Log should contain header line"
    exit 1
fi
if ! grep -q "PID:" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: Log header should contain PID"
    exit 1
fi
echo "  PASS: temp log file created with header"

# ============================================================================
echo "Test 2: tee captures stdout output to log file"
# ============================================================================
echo "test-output-for-tee"
# Give tee a moment to flush
sleep 0.1
if ! grep -q "test-output-for-tee" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: Log should capture stdout via tee"
    cat "$CLAUDE_CAGE_SESSION_LOG"
    exit 1
fi
echo "  PASS: tee captures stdout to log"

# ============================================================================
echo "Test 3: finalize_session_log renames temp to final name"
# ============================================================================
local_temp_path="$CLAUDE_CAGE_SESSION_LOG"
finalize_session_log "test-session-001"

expected_path="$CLAUDE_CAGE_CACHE/logs/test-session-001.log"
if [ "$CLAUDE_CAGE_SESSION_LOG" != "$expected_path" ]; then
    echo "FAIL: CLAUDE_CAGE_SESSION_LOG should be updated to $expected_path, got: $CLAUDE_CAGE_SESSION_LOG"
    exit 1
fi
if [ ! -f "$expected_path" ]; then
    echo "FAIL: Final log file should exist at $expected_path"
    exit 1
fi
if [ -f "$local_temp_path" ]; then
    echo "FAIL: Temp log file should be gone after finalize"
    exit 1
fi
echo "  PASS: finalize renames temp to session-named log"

# ============================================================================
echo "Test 4: tee still writes to renamed file"
# ============================================================================
echo "after-finalize-output"
sleep 0.1
if ! grep -q "after-finalize-output" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: Tee should still write to log after rename (same inode)"
    exit 1
fi
echo "  PASS: tee continues writing after rename"

# ============================================================================
echo "Test 5: restore_original_fds stops tee capture"
# ============================================================================
restore_original_fds
echo "after-restore-output"
sleep 0.1
if grep -q "after-restore-output" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: Output after restore should NOT appear in log"
    exit 1
fi
echo "  PASS: restore_original_fds stops tee capture"

# ============================================================================
echo "Test 6: append_session_log writes directly to log"
# ============================================================================
append_session_log "direct-append-test"
if ! grep -q "direct-append-test" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: append_session_log should write directly to log file"
    exit 1
fi
echo "  PASS: append_session_log writes directly"

# ============================================================================
echo "Test 7: append_session_log is no-op when CLAUDE_CAGE_SESSION_LOG is empty"
# ============================================================================
saved_log="$CLAUDE_CAGE_SESSION_LOG"
CLAUDE_CAGE_SESSION_LOG=""
append_session_log "should-not-appear"  # should not error
CLAUDE_CAGE_SESSION_LOG="$saved_log"
echo "  PASS: append_session_log handles empty path gracefully"

# ============================================================================
echo "Test 8: sync_log writes to both sync log and session log"
# ============================================================================
sync_log_file="$TEST_TMP/test-sync.log"
sync_log "$sync_log_file" "abc12345" ">>source" "test sync message"
if ! grep -q "abc12345" "$sync_log_file"; then
    echo "FAIL: sync_log should write to sync log file"
    exit 1
fi
if ! grep -q "\[sync\].*abc12345" "$CLAUDE_CAGE_SESSION_LOG"; then
    echo "FAIL: sync_log should write [sync]-prefixed entry to session log"
    exit 1
fi
echo "  PASS: sync_log writes to both logs"

# ============================================================================
echo "Test 9: sync_log works when session log is unset"
# ============================================================================
saved_log="$CLAUDE_CAGE_SESSION_LOG"
CLAUDE_CAGE_SESSION_LOG=""
sync_log_file2="$TEST_TMP/test-sync2.log"
sync_log "$sync_log_file2" "def67890" ">>intermediary" "no session log"
CLAUDE_CAGE_SESSION_LOG="$saved_log"
if ! grep -q "def67890" "$sync_log_file2"; then
    echo "FAIL: sync_log should still write to sync log when session log is unset"
    exit 1
fi
echo "  PASS: sync_log works without session log"

# ============================================================================
echo "Test 10: start_session_log skips in dry-run mode"
# ============================================================================
# Reset session log state
CLAUDE_CAGE_SESSION_LOG=""
dry_run=true
start_session_log "$CLAUDE_CAGE_CACHE/logs-dryrun"
if [ -n "$CLAUDE_CAGE_SESSION_LOG" ]; then
    echo "FAIL: start_session_log should be no-op in dry-run mode"
    exit 1
fi
dry_run=false
echo "  PASS: start_session_log skips in dry-run mode"

# ============================================================================
# Test cleanup integration: clean_session_cache removes log file
# ============================================================================
echo "Test 11: clean_session_cache removes session log"

# Create a source repo for cleanup testing
mkdir -p "$TEST_TMP/cleanup-source"
cd "$TEST_TMP/cleanup-source"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add . && git commit -q -m "Initial"

CLEANUP_SOURCE="$TEST_TMP/cleanup-source"
CLAUDE_CAGE_SESSION="cleanup-session-001"
export CLAUDE_CAGE_SESSION

# Create intermediary and work dir
create_intermediary_clone "$CLEANUP_SOURCE" >/dev/null 2>&1
# Fix origin for testing outside sandbox
CLEANUP_WORK=$(get_work_path "$CLEANUP_SOURCE")
CLEANUP_INTERMEDIARY=$(get_intermediary_path "$CLEANUP_SOURCE")
git -C "$CLEANUP_WORK" remote set-url origin "$CLEANUP_INTERMEDIARY"

# Create a log file for this session (remove any leftover logs from earlier tests first)
rm -rf "$CLAUDE_CAGE_CACHE/logs"
mkdir -p "$CLAUDE_CAGE_CACHE/logs"
echo "test log content" > "$CLAUDE_CAGE_CACHE/logs/cleanup-session-001.log"

# Run clean
clean_session_cache "$CLEANUP_SOURCE" "cleanup-session-001" >/dev/null 2>&1

if [ -f "$CLAUDE_CAGE_CACHE/logs/cleanup-session-001.log" ]; then
    echo "FAIL: clean_session_cache should remove the session log"
    exit 1
fi
echo "  PASS: clean_session_cache removes session log"

# ============================================================================
echo "Test 12: clean_session_cache removes empty logs directory"
# ============================================================================
if [ -d "$CLAUDE_CAGE_CACHE/logs" ]; then
    echo "FAIL: empty logs directory should be removed after clean"
    exit 1
fi
echo "  PASS: empty logs directory removed"

# ============================================================================
echo "Test 13: setup_caged_symlinks creates log symlink"
# ============================================================================
# Create a fresh cage for symlink testing
mkdir -p "$TEST_TMP/symlink-source"
cd "$TEST_TMP/symlink-source"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add . && git commit -q -m "Initial"

SYMLINK_SOURCE="$TEST_TMP/symlink-source"
CLAUDE_CAGE_SESSION="symlink-session-001"
export CLAUDE_CAGE_SESSION

create_intermediary_clone "$SYMLINK_SOURCE" >/dev/null 2>&1

# Set up session log pointing to a real file
mkdir -p "$CLAUDE_CAGE_CACHE/logs"
echo "symlink test log" > "$CLAUDE_CAGE_CACHE/logs/symlink-session-001.log"
CLAUDE_CAGE_SESSION_LOG="$CLAUDE_CAGE_CACHE/logs/symlink-session-001.log"

# Run setup_caged_symlinks
setup_caged_symlinks "$SYMLINK_SOURCE" ""

caged_log_link="$SYMLINK_SOURCE/.caged/sessions/symlink-session-001/log"
if [ ! -L "$caged_log_link" ]; then
    echo "FAIL: .caged/sessions/<id>/log symlink should exist"
    exit 1
fi
if [ ! -f "$caged_log_link" ]; then
    echo "FAIL: log symlink should point to a valid file"
    exit 1
fi
link_target=$(readlink "$caged_log_link")
if [ "$link_target" != "$CLAUDE_CAGE_SESSION_LOG" ]; then
    echo "FAIL: log symlink should point to $CLAUDE_CAGE_SESSION_LOG, got: $link_target"
    exit 1
fi
echo "  PASS: setup_caged_symlinks creates log symlink"

# ============================================================================
echo "Test 14: setup_caged_symlinks skips log symlink when session log unset"
# ============================================================================
saved_log="$CLAUDE_CAGE_SESSION_LOG"
CLAUDE_CAGE_SESSION_LOG=""
CLAUDE_CAGE_SESSION="symlink-session-002"
export CLAUDE_CAGE_SESSION

# Create work dir for the new session
SYMLINK_WORK2=$(get_work_path "$SYMLINK_SOURCE")
SYMLINK_INTERMEDIARY=$(get_intermediary_path "$SYMLINK_SOURCE")
mkdir -p "$SYMLINK_WORK2"
git clone --quiet "$SYMLINK_INTERMEDIARY" "$SYMLINK_WORK2" 2>/dev/null || true

setup_caged_symlinks "$SYMLINK_SOURCE" "" 2>/dev/null

caged_log_link2="$SYMLINK_SOURCE/.caged/sessions/symlink-session-002/log"
if [ -L "$caged_log_link2" ]; then
    echo "FAIL: log symlink should NOT be created when session log is unset"
    exit 1
fi
CLAUDE_CAGE_SESSION_LOG="$saved_log"
echo "  PASS: no log symlink when session log unset"

# ============================================================================
echo "Test 15: cleanup_stale_caged_links prunes broken work symlinks"
# ============================================================================
mkdir -p "$TEST_TMP/caged-source"
cd "$TEST_TMP/caged-source"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add . && git commit -q -m "Initial"

CAGED_SOURCE="$TEST_TMP/caged-source"

mkdir -p "$CAGED_SOURCE/.caged/sessions/dead-session/"
ln -s "$TEST_TMP/does-not-exist" "$CAGED_SOURCE/.caged/sessions/dead-session/work"

mkdir -p "$CAGED_SOURCE/.caged/sessions/live-session/"
mkdir -p "$TEST_TMP/live-target"
ln -s "$TEST_TMP/live-target" "$CAGED_SOURCE/.caged/sessions/live-session/work"

cleanup_stale_caged_links "$CAGED_SOURCE" >/dev/null 2>&1 || true

if [ -d "$CAGED_SOURCE/.caged/sessions/dead-session" ]; then
    echo "FAIL: dead-session with broken work symlink should be pruned"
    exit 1
fi
if [ ! -d "$CAGED_SOURCE/.caged/sessions/live-session" ]; then
    echo "FAIL: live-session with valid work symlink should be kept"
    exit 1
fi
echo "  PASS: cleanup_stale_caged_links prunes broken work symlinks"

# ============================================================================
echo "Test 17: cleanup_stale_caged_links removes empty .caged dir"
# ============================================================================
mkdir -p "$TEST_TMP/empty-caged-source"
cd "$TEST_TMP/empty-caged-source"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add . && git commit -q -m "Initial"

EMPTY_CAGED_SOURCE="$TEST_TMP/empty-caged-source"

mkdir -p "$EMPTY_CAGED_SOURCE/.caged/sessions/orphan/"
ln -s "$TEST_TMP/does-not-exist-either" "$EMPTY_CAGED_SOURCE/.caged/sessions/orphan/work"
printf '*\n!.gitignore\n' > "$EMPTY_CAGED_SOURCE/.caged/.gitignore"

cleanup_stale_caged_links "$EMPTY_CAGED_SOURCE" >/dev/null 2>&1 || true

if [ -d "$EMPTY_CAGED_SOURCE/.caged" ]; then
    echo "FAIL: .caged dir should be removed when only .gitignore remains"
    exit 1
fi
echo "  PASS: cleanup_stale_caged_links removes empty .caged dir"

# ============================================================================
echo "Test 18: cleanup_stale_caged_links no-op when .caged missing"
# ============================================================================
mkdir -p "$TEST_TMP/no-caged-source"
cd "$TEST_TMP/no-caged-source"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "content" > file.txt
git add . && git commit -q -m "Initial"

NO_CAGED_SOURCE="$TEST_TMP/no-caged-source"

cleanup_stale_caged_links "$NO_CAGED_SOURCE" >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "FAIL: cleanup_stale_caged_links should succeed when .caged missing"
    exit 1
fi
echo "  PASS: cleanup_stale_caged_links no-op when .caged missing"

echo ""
echo "=== All session logging tests passed! ==="
