#!/bin/bash
# Test the guards around rebuilding an intermediary and recreating a work dir:
# exclude changes are detected on every start, a rebuild is refused while
# another session uses the intermediary or while cages hold unsaved work, and
# a work dir with unsaved work is never wiped silently.

set -e

# Unset sandbox env vars to allow testing from inside a sandbox
unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
CAGE="$CAGE_DIR/dist/claude-cage"
TEST_TMP=$(mktemp -d)

export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export CLAUDE_CAGE_MOUNTED_PIPE="$TEST_TMP/.runtime/claude-cage/test-pipe"
export HOME="$TEST_TMP"

OTHER_PID=""
cleanup() {
    if [ -n "$OTHER_PID" ]; then
        kill "$OTHER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

SOURCE_PATH="$TEST_TMP/source"
INTERMEDIARY_DIR="$CLAUDE_CAGE_CACHE/intermediary$SOURCE_PATH"
WORK_DIR="$CLAUDE_CAGE_CACHE/sessions/default/work$SOURCE_PATH"
HASH_FILE="$INTERMEDIARY_DIR/claude-cage-exclude-hash"

# Start the cage non-interactively; the sandbox itself may fail to launch
# here, but all the setup under test happens before that.
run_cage() {
    env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" \
        CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
        GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@test.com" \
        GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@test.com" \
        bash -c 'cd "$1" && echo "exit" | "$2" --test 2>&1' _ "$SOURCE_PATH" "$CAGE"
}

write_config() {
    cat > "$SOURCE_PATH/.claude-cage" << EOF
claude_cage {
    showBanner = false,
    hideConfirmationPrompt = true,
    exclude = { $1 }
}
EOF
}

fail() {
    echo "FAIL: $1"
    if [ -n "${2:-}" ]; then
        echo "Output was:"
        echo "$2"
    fi
    exit 1
}

work_commit() {
    git -C "$WORK_DIR" -c user.email=t@e -c user.name=t commit -q --allow-empty -m "$1"
}

echo "=== Testing intermediary rebuild guards ==="
echo ""

mkdir -p "$SOURCE_PATH"
cd "$SOURCE_PATH"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "content" > file.txt
echo "secret" > secret.txt
echo "key" > key.txt
echo ".claude-cage" > .gitignore
git add .
git commit -q -m "Initial"
write_config '"secret.txt"'

run_cage >/dev/null || true
[ -d "$WORK_DIR/.git" ] || fail "setup: work dir should exist after first run"
first_hash=$(cat "$HASH_FILE")

echo "Test 1: an exclude change is caught when the cage is reused"
write_config '"secret.txt", "key.txt"'
output=$(run_cage) || true
echo "$output" | grep -q "exclude patterns changed" \
    || fail "expected exclude change to be reported" "$output"
[ "$(cat "$HASH_FILE")" != "$first_hash" ] || fail "intermediary should be rebuilt" "$output"
if git -C "$INTERMEDIARY_DIR" cat-file -e HEAD:key.txt 2>/dev/null; then
    fail "newly excluded key.txt should be gone from the intermediary"
fi
echo "  PASS: reused cage rebuilt for new excludes"

echo "Test 2: no rebuild when excludes are unchanged"
output=$(run_cage) || true
if echo "$output" | grep -q "exclude patterns changed"; then
    fail "unchanged excludes should not trigger a rebuild" "$output"
fi
echo "  PASS: unchanged excludes leave the intermediary alone"

echo "Test 3: rebuild refused while another session is active"
sleep 300 &
OTHER_PID=$!
mkdir -p "$CLAUDE_CAGE_RUNTIME/sessions/default"
echo "$SOURCE_PATH" > "$CLAUDE_CAGE_RUNTIME/sessions/default/$OTHER_PID"
hash_before=$(cat "$HASH_FILE")
write_config '"secret.txt"'
if output=$(run_cage); then
    fail "start should fail while another session uses the intermediary" "$output"
fi
echo "$output" | grep -q "Another session for this project is still usin'" \
    || fail "expected active-session refusal" "$output"
[ "$(cat "$HASH_FILE")" = "$hash_before" ] || fail "intermediary should not be rebuilt"
if ls "$CLAUDE_CAGE_CACHE/sessions" | grep -q -- "-2$"; then
    fail "refused start should not claim an alternate session"
fi
kill "$OTHER_PID" 2>/dev/null || true
wait "$OTHER_PID" 2>/dev/null || true
OTHER_PID=""
rm -f "$CLAUDE_CAGE_RUNTIME/sessions/default/"*
echo "  PASS: active session blocks the rebuild"

echo "Test 4: rebuild refused when a cage has unpushed commits"
work_commit "unpushed work"
if output=$(run_cage); then
    fail "start should fail when a cage holds unpushed commits" "$output"
fi
echo "$output" | grep -q "default: unpushed commits" \
    || fail "expected the cage with unpushed commits to be listed" "$output"
[ "$(cat "$HASH_FILE")" = "$hash_before" ] || fail "intermediary should not be rebuilt"
[ "$(git -C "$WORK_DIR" log -1 --format=%s)" = "unpushed work" ] \
    || fail "unpushed commit should survive"
echo "  PASS: unpushed work blocks the rebuild"

echo "Test 5: rebuild refused when a cage has uncommitted changes"
git -C "$WORK_DIR" reset -q --hard HEAD~1
echo "edit" >> "$WORK_DIR/file.txt"
if output=$(run_cage); then
    fail "start should fail when a cage holds uncommitted changes" "$output"
fi
echo "$output" | grep -q "default: uncommitted changes" \
    || fail "expected the dirty cage to be listed" "$output"
grep -q "edit" "$WORK_DIR/file.txt" || fail "uncommitted change should survive"
git -C "$WORK_DIR" checkout -q -- file.txt
echo "  PASS: uncommitted work blocks the rebuild"

echo "Test 6: missing intermediary does not wipe a work dir with unpushed commits"
write_config '"secret.txt", "key.txt"'
run_cage >/dev/null || true
work_commit "precious"
rm -rf "$INTERMEDIARY_DIR"
if output=$(run_cage); then
    fail "start should fail rather than wipe unpushed commits" "$output"
fi
echo "$output" | grep -q "settin' it up fresh would wipe" \
    || fail "expected the wipe refusal" "$output"
[ "$(git -C "$WORK_DIR" log -1 --format=%s)" = "precious" ] \
    || fail "unpushed commit should survive a missing intermediary"
echo "  PASS: work dir kept when intermediary is missing"

echo "Test 7: a clean work dir is still recreated when the intermediary is missing"
rm -rf "$WORK_DIR" "$INTERMEDIARY_DIR"
run_cage >/dev/null || true
rm -rf "$INTERMEDIARY_DIR"
output=$(run_cage) || true
[ -d "$INTERMEDIARY_DIR" ] || fail "intermediary should be rebuilt" "$output"
[ -d "$WORK_DIR/.git" ] || fail "work dir should be recreated" "$output"
echo "  PASS: clean work dir recreated"

echo "Test 8: a clean cage from an older intermediary build is set up fresh"
mv "$WORK_DIR" "$TEST_TMP/old-work"
write_config '"secret.txt"'
run_cage >/dev/null || true
rm -rf "$WORK_DIR"
mv "$TEST_TMP/old-work" "$WORK_DIR"
output=$(run_cage) || true
echo "$output" | grep -q "older build of the intermediary" \
    || fail "expected the stale cage to be detected" "$output"
tracked=$(git -C "$WORK_DIR" rev-parse origin/master)
git -C "$INTERMEDIARY_DIR" cat-file -e "${tracked}^{commit}" \
    || fail "recreated cage should track the current intermediary" "$output"
echo "  PASS: stale clean cage recreated"

echo "Test 9: a stale cage with unpushed commits is not wiped"
mv "$WORK_DIR" "$TEST_TMP/old-work"
write_config '"secret.txt", "key.txt"'
run_cage >/dev/null || true
rm -rf "$WORK_DIR"
mv "$TEST_TMP/old-work" "$WORK_DIR"
work_commit "salvage me"
if output=$(run_cage); then
    fail "start should fail rather than wipe a stale cage's commits" "$output"
fi
echo "$output" | grep -q "settin' it up fresh would wipe" \
    || fail "expected the wipe refusal" "$output"
[ "$(git -C "$WORK_DIR" log -1 --format=%s)" = "salvage me" ] \
    || fail "stale cage's commit should survive"
echo "  PASS: stale cage with unpushed commits kept"

echo ""
echo "=== All rebuild guard tests passed ==="
