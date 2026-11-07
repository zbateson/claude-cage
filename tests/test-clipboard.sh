#!/bin/bash
# Test clipboard.sh: config parsing, mode resolution, and the go-between
# (cage-side wl-copy/wl-paste stand-ins + host listener) against stub tools

set -e

unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export HOME="$TEST_TMP"

cleanup() {
    [ -n "${CLIPBOARD_LISTENER_PID:-}" ] && kill "$CLIPBOARD_LISTENER_PID" 2>/dev/null
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    shift
    for extra in "$@"; do
        echo "$extra"
    done
    exit 1
}

echo "=== Testing clipboard.sh ==="
echo ""

CLAUDE_CAGE_SOURCING=1 source "$CAGE_DIR/dist/claude-cage"
set +e

# ---------------------------------------------------------------------------
echo "=== Config parsing ==="

mkdir -p "$TEST_TMP/cfg"
parse_clipboard() {
    (
        parse_config "proj" "$TEST_TMP/cfg" "$@" >/dev/null 2>&1 || exit 1
        echo "$cfg_clipboard_write|$cfg_clipboard_read|$cfg_clipboard_write_set|$cfg_clipboard_read_set"
    )
}
parse_clipboard_err() {
    ( parse_config "proj" "$TEST_TMP/cfg" "$@" 2>&1 )
}

echo "Test 1: No clipboard table defaults to notify/confirm"
cat > "$TEST_TMP/cfg/none" << 'EOF'
claude_cage { showBanner = false }
EOF
result=$(parse_clipboard "$TEST_TMP/cfg/none")
[ "$result" = "notify|confirm|default|default" ] || fail "got '$result'"
echo "  PASS: Defaults are notify/confirm"

echo "Test 2: Keys merge one at a time across config levels"
cat > "$TEST_TMP/cfg/user" << 'EOF'
claude_cage { clipboard = { write = "allow", read = "allow" } }
EOF
cat > "$TEST_TMP/cfg/local" << 'EOF'
claude_cage { clipboard = { read = "deny" } }
EOF
result=$(parse_clipboard "$TEST_TMP/cfg/user" "$TEST_TMP/cfg/local")
[ "$result" = "allow|deny|explicit|explicit" ] || fail "got '$result'"
echo "  PASS: Project read override keeps user-level write"

echo "Test 3: Malformed clipboard settings stop the config load"
for bad in 'clipboard = true' 'clipboard = "open"' 'clipboard = { write = "maybe" }' \
           'clipboard = { read = "notify" }' 'clipboard = { paste = "allow" }'; do
    printf 'claude_cage { %s }\n' "$bad" > "$TEST_TMP/cfg/bad"
    if parse_clipboard "$TEST_TMP/cfg/bad" >/dev/null; then
        fail "accepted: $bad"
    fi
    err=$(parse_clipboard_err "$TEST_TMP/cfg/bad")
    echo "$err" | grep -q 'clipboard = { write = "allow|notify|confirm|deny"' || \
        fail "no usage hint for: $bad" "$err"
done
echo "  PASS: Rejects booleans, strings, unknown keys and values"

# ---------------------------------------------------------------------------
echo ""
echo "=== Mode resolution ==="

detect_clipboard_backend() { echo "$fake_backend"; }
detect_clipboard_dialog() { echo "$fake_dialog"; }
detect_clipboard_notifier() { echo "$fake_notifier"; }
with_tools() {
    fake_backend="$1"
    fake_dialog="$2"
    fake_notifier="$3"
}

echo "Test 4: Defaults hold when the host has every tool"
with_tools wayland zenity notify-send
cfg_clipboard_write=notify cfg_clipboard_read=confirm
cfg_clipboard_write_set=default cfg_clipboard_read_set=default
warn=$(resolve_clipboard_modes 2>&1); resolve_clipboard_modes 2>/dev/null
[ "$clipboard_write_mode/$clipboard_read_mode" = "notify/confirm" ] || \
    fail "got $clipboard_write_mode/$clipboard_read_mode"
[ -z "$warn" ] || fail "unexpected warning" "$warn"
echo "  PASS: notify/confirm"

echo "Test 5: Defaults fall back quietly without dialog or notifier"
with_tools wayland "" ""
warn=$(resolve_clipboard_modes 2>&1); resolve_clipboard_modes 2>/dev/null
[ "$clipboard_write_mode/$clipboard_read_mode" = "allow/deny" ] || \
    fail "got $clipboard_write_mode/$clipboard_read_mode"
[ -z "$warn" ] || fail "defaults should not warn" "$warn"
echo "  PASS: allow/deny, no warning"

echo "Test 6: Explicit settings that can't be honoured warn"
cfg_clipboard_write_set=explicit cfg_clipboard_read_set=explicit
warn=$(resolve_clipboard_modes 2>&1)
echo "$warn" | grep -q 'clipboard.read = "confirm" needs' || fail "no read warning" "$warn"
echo "$warn" | grep -q 'clipboard.write = "notify" needs' || fail "no write warning" "$warn"
echo "  PASS: Warns about both"

echo "Test 7: No clipboard tool on the host turns it all off"
with_tools "" zenity notify-send
cfg_clipboard_write_set=default cfg_clipboard_read_set=default
warn=$(resolve_clipboard_modes 2>&1); resolve_clipboard_modes 2>/dev/null
[ "$clipboard_write_mode/$clipboard_read_mode" = "deny/deny" ] || \
    fail "got $clipboard_write_mode/$clipboard_read_mode"
clipboard_enabled && fail "should be disabled"
[ -z "$warn" ] || fail "defaults should not warn" "$warn"
cfg_clipboard_read_set=explicit
warn=$(resolve_clipboard_modes 2>&1)
echo "$warn" | grep -q "no clipboard tool" || fail "explicit setting should warn" "$warn"
echo "  PASS: Off, warning only when explicit"

# ---------------------------------------------------------------------------
echo ""
echo "=== Go-between ==="

STUB="$TEST_TMP/stub"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/wl-copy" << EOF
#!/bin/sh
[ "\$1" = "--type" ] && printf '%s' "\$2" > "$STUB/clip.type"
cat > "$STUB/clip"
EOF
cat > "$STUB/bin/wl-paste" << EOF
#!/bin/sh
case "\$1" in
    --list-types) [ -f "$STUB/types" ] && cat "$STUB/types"; exit 0 ;;
esac
[ -s "$STUB/clip" ] || exit 1
cat "$STUB/clip"
EOF
cat > "$STUB/bin/zenity" << EOF
#!/bin/sh
echo "\$*" >> "$STUB/zenity.log"
exit \$(cat "$STUB/zenity-answer")
EOF
cat > "$STUB/bin/notify-send" << EOF
#!/bin/sh
echo "\$*" >> "$STUB/notify.log"
EOF
chmod +x "$STUB"/bin/*
export PATH="$STUB/bin:$PATH"

reset_stub() {
    rm -f "$STUB/clip" "$STUB/clip.type" "$STUB/types" "$STUB/zenity.log" "$STUB/notify.log"
    echo 1 > "$STUB/zenity-answer"
}

CLAUDE_CAGE_SESSION="test"
cfg_project="proj"
setup_clipboard_dir
clipboard_backend=wayland
clipboard_dialog=zenity
clipboard_notifier=notify-send
export CLAUDE_CAGE_CLIPBOARD_DIR="$clipboard_base/cage"
export CLAUDE_CAGE_CLIPBOARD_INBOX="$clipboard_base/inbox"
SHIM="$clipboard_base/cage/bin"

queued() {
    ls "$clipboard_base/inbox/queue" | wc -l | tr -d ' '
}

echo "Test 8: Copy with write=allow goes straight to the clipboard"
reset_stub
clipboard_write_mode=allow
printf 'hello' | "$SHIM/wl-copy"
_clipboard_pass 1
[ "$(cat "$STUB/clip" 2>/dev/null)" = "hello" ] || fail "clipboard not written"
[ ! -f "$STUB/notify.log" ] || fail "allow should not notify"
echo "  PASS: Copied silently"

echo "Test 9: Copy with write=notify copies and sends a notification"
reset_stub
clipboard_write_mode=notify
"$SHIM/wl-copy" "some text"
_clipboard_pass 1
[ "$(cat "$STUB/clip" 2>/dev/null)" = "some text" ] || fail "clipboard not written"
grep -q 'proj cage copied "some text"' "$STUB/notify.log" 2>/dev/null || \
    fail "no notification" "$(cat "$STUB/notify.log" 2>/dev/null)"
echo "  PASS: Copied and notified"

echo "Test 10: Copy with write=deny never reaches the clipboard"
reset_stub
clipboard_write_mode=deny
printf 'nope' | "$SHIM/wl-copy"
_clipboard_pass 1
[ ! -f "$STUB/clip" ] || fail "clipboard was written"
echo "  PASS: Denied"

echo "Test 11: Copy with write=confirm follows the answer"
reset_stub
clipboard_write_mode=confirm
printf 'first' | "$SHIM/wl-copy"
_clipboard_pass 1
[ ! -f "$STUB/clip" ] || fail "denied prompt still copied"
echo 0 > "$STUB/zenity-answer"
printf 'second' | "$SHIM/wl-copy"
_clipboard_pass 1
[ "$(cat "$STUB/clip" 2>/dev/null)" = "second" ] || fail "allowed prompt didn't copy"
grep -q -- '--default-cancel' "$STUB/zenity.log" || fail "prompt should default to Deny"
echo "  PASS: Deny then Allow"

echo "Test 12: --primary copies are dropped without a request"
reset_stub
clipboard_write_mode=allow
printf 'x' | "$SHIM/wl-copy" --primary
[ "$(queued)" = 0 ] || fail "primary copy was queued"
echo "  PASS: No request"

echo "Test 13: Copies over the size limit are refused"
reset_stub
saved_max=$CLIPBOARD_MAX_WRITE_BYTES
CLIPBOARD_MAX_WRITE_BYTES=4
printf 'too long' | "$SHIM/wl-copy"
_clipboard_pass 1
CLIPBOARD_MAX_WRITE_BYTES=$saved_max
[ ! -f "$STUB/clip" ] || fail "oversized copy got through"
echo "  PASS: Refused"

echo "Test 14: A symlinked request file can't pull in a host file"
reset_stub
clipboard_write_mode=allow
echo "host secret" > "$TEST_TMP/secret"
mkdir "$clipboard_base/inbox/queue/evil1"
printf 'copy' > "$clipboard_base/inbox/queue/evil1/op"
ln -s "$TEST_TMP/secret" "$clipboard_base/inbox/queue/evil1/data"
ln -s "$TEST_TMP" "$clipboard_base/inbox/queue/evil2"
_clipboard_pass 1
[ ! -f "$STUB/clip" ] || fail "symlinked data reached the clipboard"
[ -f "$TEST_TMP/secret" ] || fail "symlink target was touched"
[ "$(queued)" = 0 ] || fail "bad requests left in the queue"
echo "  PASS: Ignored and cleared"

echo "Test 15: Odd MIME types are rejected"
reset_stub
"$SHIM/wl-copy" --type 'text/plain$(id)' "x"
_clipboard_pass 1
[ ! -f "$STUB/clip" ] || fail "bad type was accepted"
echo "  PASS: Rejected"

# The listener is a forked subshell, so it only sees modes set before it starts
listen_with_read_mode() {
    stop_clipboard_listener
    clipboard_read_mode="$1"
    start_clipboard_listener
}

echo "Test 16: Listing types never prompts"
reset_stub
listen_with_read_mode confirm
printf 'text/plain\nimage/png\n' > "$STUB/types"
types=$("$SHIM/wl-paste" -l)
echo "$types" | grep -q 'image/png' || fail "types not listed" "$types"
[ ! -f "$STUB/zenity.log" ] || fail "listing prompted"
echo "  PASS: Listed without asking"

echo "Test 17: Reads with read=confirm follow the answer"
reset_stub
printf 'secret' > "$STUB/clip"
if "$SHIM/wl-paste" > "$TEST_TMP/out" 2>/dev/null; then
    fail "denied read returned data"
fi
[ ! -s "$TEST_TMP/out" ] || fail "denied read leaked data"
echo 0 > "$STUB/zenity-answer"
out=$("$SHIM/wl-paste" -n) || fail "allowed read failed"
[ "$out" = "secret" ] || fail "got '$out'"
grep -q 'read your clipboard' "$STUB/zenity.log" || fail "no read prompt"
echo "  PASS: Deny then Allow"

echo "Test 18: Reads with read=allow don't prompt; read=deny refuses"
reset_stub
printf 'data' > "$STUB/clip"
listen_with_read_mode allow
out=$("$SHIM/wl-paste" -n) || fail "allowed read failed"
[ "$out" = "data" ] || fail "got '$out'"
listen_with_read_mode deny
if "$SHIM/wl-paste" -n >/dev/null 2>&1; then
    fail "denied read succeeded"
fi
if [ -n "$("$SHIM/wl-paste" -l 2>/dev/null)" ]; then
    fail "read=deny still listed types"
fi
[ ! -f "$STUB/zenity.log" ] || fail "should not prompt"
echo "  PASS: allow and deny"

echo "Test 19: An empty clipboard doesn't prompt"
reset_stub
listen_with_read_mode confirm
if "$SHIM/wl-paste" >/dev/null 2>&1; then
    fail "empty read succeeded"
fi
[ ! -f "$STUB/zenity.log" ] || fail "prompted for nothing"
echo "  PASS: No prompt"

stop_clipboard_listener

echo "Test 20: Only one prompt at a time; the rest are denied"
reset_stub
echo 0 > "$STUB/zenity-answer"
printf 'data' > "$STUB/clip"
for n in 1 2 3; do
    mkdir "$clipboard_base/inbox/queue/req$n"
    printf 'paste' > "$clipboard_base/inbox/queue/req$n/op"
done
_clipboard_pass 1
[ "$(wc -l < "$STUB/zenity.log" | tr -d ' ')" = 1 ] || fail "prompted more than once"
statuses=$(for f in "$clipboard_base"/cage/replies/req*/status; do cat "$f"; echo; done | sort | tr '\n' ' ')
[ "$statuses" = "denied denied ok " ] || fail "got statuses: $statuses"
echo "  PASS: One prompt, others denied"

echo "Test 21: wl-paste gives up when no listener answers"
start=$(date +%s)
if "$SHIM/wl-paste" >/dev/null 2>&1; then
    fail "succeeded with no listener"
fi
[ $(( $(date +%s) - start )) -lt 10 ] || fail "took too long to give up"
echo "  PASS: Gave up quickly"

echo "Test 22: Cleanup removes the go-between directory"
cleanup_clipboard_dir
[ ! -d "$clipboard_base" ] || fail "directory left behind"
echo "  PASS: Removed"

echo ""
echo "=== All clipboard tests passed! ==="
