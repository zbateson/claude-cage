#!/bin/bash
# Test session-naming helpers in git-clone.sh
# Covers get_project_key, allocate_alternate_session, resolve_session_name,
# display_session_name.

set -e

unset CLAUDE_CAGE_SOURCING

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP=$(mktemp -d)

export CLAUDE_CAGE_CACHE="$TEST_TMP/.cache/claude-cage"
export CLAUDE_CAGE_RUNTIME="$TEST_TMP/.runtime/claude-cage"
export HOME="$TEST_TMP"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "=== Testing session-naming helpers ==="
echo ""

export CLAUDE_CAGE_SOURCING=1
# shellcheck source=/dev/null
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

PROJ_A="$TEST_TMP/projects/alpha"
PROJ_B="$TEST_TMP/projects/beta"
PROJ_A_DUP="$TEST_TMP/elsewhere/alpha"  # same basename, different path
mkdir -p "$PROJ_A" "$PROJ_B" "$PROJ_A_DUP"

KEY_A=$(get_project_key "$PROJ_A")
KEY_B=$(get_project_key "$PROJ_B")
KEY_A_DUP=$(get_project_key "$PROJ_A_DUP")

echo "Test 1: get_project_key format is <basename>-<6-hex-hash>"
if [[ "$KEY_A" =~ ^alpha-[a-f0-9]{6}$ ]]; then
    echo "  PASS: $KEY_A"
else
    echo "  FAIL: expected alpha-<6-hex>, got '$KEY_A'"
    exit 1
fi

echo "Test 2: different projects with same basename get distinct keys"
if [ "$KEY_A" != "$KEY_A_DUP" ]; then
    echo "  PASS: $KEY_A != $KEY_A_DUP"
else
    echo "  FAIL: same key for distinct paths"
    exit 1
fi

echo "Test 3: same source dir always produces the same key"
KEY_A2=$(get_project_key "$PROJ_A")
if [ "$KEY_A" = "$KEY_A2" ]; then
    echo "  PASS: stable"
else
    echo "  FAIL: '$KEY_A' vs '$KEY_A2'"
    exit 1
fi

echo ""
echo "=== allocate_alternate_session ==="

echo "Test 4: empty cache → first allocation is N=2"
NAME1=$(allocate_alternate_session "$PROJ_A")
if [ "$NAME1" = "${KEY_A}-2" ]; then
    echo "  PASS: $NAME1"
else
    echo "  FAIL: expected ${KEY_A}-2, got '$NAME1'"
    exit 1
fi
[ -d "$CLAUDE_CAGE_CACHE/sessions/$NAME1" ] || { echo "  FAIL: slot dir not created"; exit 1; }

echo "Test 5: with .2 existing, next allocation is .3"
NAME2=$(allocate_alternate_session "$PROJ_A")
if [ "$NAME2" = "${KEY_A}-3" ]; then
    echo "  PASS: $NAME2"
else
    echo "  FAIL: expected ${KEY_A}-3, got '$NAME2'"
    exit 1
fi

echo "Test 6: gap (existing .2 and .4, no .3) → next is .5, not .3"
rm -rf "$CLAUDE_CAGE_CACHE/sessions/${KEY_A}-3"
mkdir -p "$CLAUDE_CAGE_CACHE/sessions/${KEY_A}-4"
NAME3=$(allocate_alternate_session "$PROJ_A")
if [ "$NAME3" = "${KEY_A}-5" ]; then
    echo "  PASS: $NAME3 (holes not filled)"
else
    echo "  FAIL: expected ${KEY_A}-5, got '$NAME3'"
    exit 1
fi

echo "Test 7: after removing all alternates, next allocation restarts at .2"
rm -rf "$CLAUDE_CAGE_CACHE/sessions/${KEY_A}-"*
NAME4=$(allocate_alternate_session "$PROJ_A")
if [ "$NAME4" = "${KEY_A}-2" ]; then
    echo "  PASS: $NAME4 (slot recycled)"
else
    echo "  FAIL: expected ${KEY_A}-2 after cleanup, got '$NAME4'"
    exit 1
fi

echo "Test 8: allocation is scoped per project — proj B unaffected by proj A's slots"
NAME_B=$(allocate_alternate_session "$PROJ_B")
if [ "$NAME_B" = "${KEY_B}-2" ]; then
    echo "  PASS: $NAME_B"
else
    echo "  FAIL: expected ${KEY_B}-2, got '$NAME_B'"
    exit 1
fi

echo "Test 9: concurrent allocations resolve to distinct slots"
rm -rf "$CLAUDE_CAGE_CACHE/sessions/${KEY_A}-"*
RES_FILE=$(mktemp)
(allocate_alternate_session "$PROJ_A" >> "$RES_FILE") &
(allocate_alternate_session "$PROJ_A" >> "$RES_FILE") &
(allocate_alternate_session "$PROJ_A" >> "$RES_FILE") &
wait
# Sort the three results; expect .2 .3 .4 each appearing exactly once.
sorted=$(sort "$RES_FILE" | tr '\n' ' ')
expected="${KEY_A}-2 ${KEY_A}-3 ${KEY_A}-4 "
if [ "$sorted" = "$expected" ]; then
    echo "  PASS: distinct slots ($sorted)"
else
    echo "  FAIL: expected '$expected', got '$sorted'"
    exit 1
fi
rm -f "$RES_FILE"

echo ""
echo "=== resolve_session_name ==="

echo "Test 10: 'default' resolves to 'default'"
got=$(resolve_session_name "default" "$PROJ_A")
if [ "$got" = "default" ]; then
    echo "  PASS"
else
    echo "  FAIL: got '$got'"
    exit 1
fi

echo "Test 11: 'session.2' resolves to '<key>-2'"
got=$(resolve_session_name "session.2" "$PROJ_A")
if [ "$got" = "${KEY_A}-2" ]; then
    echo "  PASS: $got"
else
    echo "  FAIL: expected ${KEY_A}-2, got '$got'"
    exit 1
fi

echo "Test 12: 'session.42' resolves to '<key>-42'"
got=$(resolve_session_name "session.42" "$PROJ_A")
if [ "$got" = "${KEY_A}-42" ]; then
    echo "  PASS: $got"
else
    echo "  FAIL: got '$got'"
    exit 1
fi

echo "Test 13: bogus name returns non-zero and writes to stderr"
if resolve_session_name "garbage" "$PROJ_A" >/dev/null 2>"$TEST_TMP/err"; then
    echo "  FAIL: should have errored"
    exit 1
fi
if grep -q "unknown session name" "$TEST_TMP/err"; then
    echo "  PASS: rejected with stderr message"
else
    echo "  FAIL: stderr was: $(cat "$TEST_TMP/err")"
    exit 1
fi

echo ""
echo "=== display_session_name ==="

echo "Test 14: 'default' → 'default'"
got=$(display_session_name "default")
if [ "$got" = "default" ]; then
    echo "  PASS"
else
    echo "  FAIL: got '$got'"
    exit 1
fi

echo "Test 15: '<basename>-<hash>-N' → 'session.N'"
got=$(display_session_name "${KEY_A}-7")
if [ "$got" = "session.7" ]; then
    echo "  PASS"
else
    echo "  FAIL: got '$got'"
    exit 1
fi

echo "Test 16: legacy timestamp passes through unchanged"
got=$(display_session_name "2026-05-16_09-22-31")
if [ "$got" = "2026-05-16_09-22-31" ]; then
    echo "  PASS"
else
    echo "  FAIL: got '$got'"
    exit 1
fi

echo "Test 17: project key with multi-word basename (claude-cage-style) renders correctly"
multi_proj="$TEST_TMP/projects/claude-cage"
mkdir -p "$multi_proj"
multi_key=$(get_project_key "$multi_proj")
got=$(display_session_name "${multi_key}-3")
if [ "$got" = "session.3" ]; then
    echo "  PASS: $got"
else
    echo "  FAIL: got '$got' from cache id '${multi_key}-3'"
    exit 1
fi

echo "Test 18: resolve / display are inverses for session.N form"
for n in 2 3 7 42 100; do
    cache=$(resolve_session_name "session.$n" "$PROJ_A")
    back=$(display_session_name "$cache")
    if [ "$back" != "session.$n" ]; then
        echo "  FAIL: session.$n → $cache → $back"
        exit 1
    fi
done
echo "  PASS"

echo ""
echo "=== All session-naming tests passed! ==="
