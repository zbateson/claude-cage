#!/bin/bash
# Test --launch, the -- separator, passthrough quoting, and
# add-launcher/remove-launcher

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

BIN_DIR="$TEST_TMP/.local/bin"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Run claude-cage in a clean env from the test source repo
run_cage() {
    env -i PATH="/usr/bin:/bin" HOME="$TEST_TMP" SHELL=/bin/bash \
        CLAUDE_CAGE_CACHE="$CLAUDE_CAGE_CACHE" CLAUDE_CAGE_RUNTIME="$CLAUDE_CAGE_RUNTIME" CLAUDE_CAGE_MOUNTED_PIPE="$CLAUDE_CAGE_MOUNTED_PIPE" \
        bash -c 'cd "$1" && shift && "$@" 2>&1' _ "$TEST_TMP/source" "$@"
}

fail() {
    echo "FAIL: $1"
    if [ -n "${2:-}" ]; then
        echo "Output was:"
        echo "$2"
    fi
    exit 1
}

echo "=== Testing launch command handling ==="
echo ""

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
    launch = "configured-tool"
}
EOF

echo "Test 1: configured launch command is used by default"
output=$(run_cage "$CAGE" --dry-run) || true
echo "$output" | grep -q "^Launchin': configured-tool$" \
    || fail "expected configured launch command" "$output"
echo "  PASS: configured launch command used"

echo "Test 2: --launch overrides the configured command"
output=$(run_cage "$CAGE" --dry-run --launch copilot) || true
echo "$output" | grep -q "^  Launch:        copilot$" \
    || fail "expected Launch: copilot" "$output"
echo "$output" | grep -q "^Launchin': copilot$" \
    || fail "expected Launchin': copilot" "$output"
echo "  PASS: --launch overrides config"

echo "Test 3: --launch=CMD form works"
output=$(run_cage "$CAGE" --dry-run --launch=codex) || true
echo "$output" | grep -q "^Launchin': codex$" \
    || fail "expected Launchin': codex" "$output"
echo "  PASS: --launch=CMD works"

echo "Test 4: launch command shows no unrecognized warning"
if echo "$output" | grep -q "unrecognized"; then
    fail "launch command should not be flagged" "$output"
fi
echo "  PASS: no unrecognized warning"

echo "Test 5: --launch without a value is rejected"
if output=$(run_cage "$CAGE" --dry-run --launch); then
    fail "--launch with no value should exit non-zero" "$output"
fi
echo "$output" | grep -q "needs a command" \
    || fail "expected missing-command message" "$output"
if output=$(run_cage "$CAGE" --dry-run --launch=); then
    fail "--launch= should exit non-zero" "$output"
fi
echo "  PASS: missing --launch value rejected"

echo "Test 6: passthrough args are shell-quoted"
output=$(run_cage "$CAGE" --dry-run --launch copilot "a b" "it's" '$HOME') || true
echo "$output" | grep -qF "Launchin': copilot a\\ b it\\'s \\\$HOME" \
    || fail "expected quoted passthrough args" "$output"
echo "  PASS: passthrough args quoted"

echo "Test 7: args after -- pass through even if claude-cage knows them"
output=$(run_cage "$CAGE" --dry-run --launch copilot -- --verbose --test) || true
echo "$output" | grep -q "^Launchin': copilot --verbose --test$" \
    || fail "expected --verbose --test passed through" "$output"
if echo "$output" | grep -q "\[run\]"; then
    fail "--verbose after -- should not enable verbose mode" "$output"
fi
echo "  PASS: -- separator passes args through"

echo ""
echo "=== Testing add-launcher / remove-launcher ==="
echo ""

echo "Test 8: add-launcher with no command prints usage"
if output=$(run_cage "$CAGE" add-launcher); then
    fail "add-launcher with no command should exit non-zero" "$output"
fi
echo "$output" | grep -q "Usage: claude-cage add-launcher" \
    || fail "expected usage" "$output"
echo "  PASS: usage shown"

echo "Test 9: add-launcher creates <cmd>-cage wrapper"
output=$(run_cage "$CAGE" add-launcher copilot) || fail "add-launcher failed" "$output"
[ -x "$BIN_DIR/copilot-cage" ] || fail "copilot-cage not created or not executable" "$output"
[ "$(sed -n 2p "$BIN_DIR/copilot-cage")" = "# claude-cage launcher" ] \
    || fail "launcher marker missing" "$(cat "$BIN_DIR/copilot-cage")"
grep -qF -- "--launch 'copilot' \"\$@\"" "$BIN_DIR/copilot-cage" \
    || fail "launcher should pass --launch copilot" "$(cat "$BIN_DIR/copilot-cage")"
echo "  PASS: wrapper created"

echo "Test 10: add-launcher warns when the command isn't installed"
echo "$output" | grep -q "can't find 'copilot'" \
    || fail "expected missing-command heads-up" "$output"
echo "  PASS: missing command warning"

echo "Test 11: add-launcher warns when ~/.local/bin isn't on PATH"
echo "$output" | grep -q "ain't on your PATH" \
    || fail "expected PATH heads-up" "$output"
echo "  PASS: PATH warning"

echo "Test 12: wrapper runs claude-cage with the launch command and args"
output=$(run_cage "$BIN_DIR/copilot-cage" --dry-run "a b") || true
echo "$output" | grep -q "^Launchin': copilot a\\\\ b$" \
    || fail "wrapper should launch copilot with args" "$output"
echo "  PASS: wrapper launches"

echo "Test 13: add-launcher accepts a custom name and quotes the command"
output=$(run_cage "$CAGE" add-launcher "it's tool" mytool) || fail "add-launcher failed" "$output"
[ -x "$BIN_DIR/mytool" ] || fail "custom-named launcher not created" "$output"
sh -n "$BIN_DIR/mytool" || fail "launcher is not valid sh" "$(cat "$BIN_DIR/mytool")"
grep -qF -- "--launch 'it'\\''s tool'" "$BIN_DIR/mytool" \
    || fail "command should be single-quoted" "$(cat "$BIN_DIR/mytool")"
echo "  PASS: custom name"

echo "Test 13b: a shell-line command is named and checked by its first word"
output=$(run_cage "$CAGE" add-launcher 'ls -d . >/dev/null || ls; ls') || fail "add-launcher failed" "$output"
[ -x "$BIN_DIR/ls-cage" ] || fail "launcher should be named ls-cage" "$output"
if echo "$output" | grep -q "can't find"; then
    fail "installed first word should not trigger the missing-command warning" "$output"
fi
sh -n "$BIN_DIR/ls-cage" || fail "launcher is not valid sh" "$(cat "$BIN_DIR/ls-cage")"
run_cage "$CAGE" remove-launcher ls-cage >/dev/null
echo "  PASS: shell-line command"

echo "Test 14: add-launcher updates its own launcher"
output=$(run_cage "$CAGE" add-launcher aider copilot-cage) || fail "re-add failed" "$output"
echo "$output" | grep -q "Launcher updated" || fail "expected update message" "$output"
grep -qF -- "--launch 'aider'" "$BIN_DIR/copilot-cage" \
    || fail "launcher should now run aider" "$(cat "$BIN_DIR/copilot-cage")"
echo "  PASS: own launcher updated"

echo "Test 15: add-launcher refuses to overwrite a foreign file"
echo "keep me" > "$BIN_DIR/other"
if output=$(run_cage "$CAGE" add-launcher copilot other); then
    fail "add-launcher should refuse a foreign file" "$output"
fi
[ "$(cat "$BIN_DIR/other")" = "keep me" ] || fail "foreign file was modified"
echo "  PASS: foreign file left alone"

echo "Test 16: unsafe launcher names are rejected"
for bad in a/b "it's-mine" "two words" ".hidden" -dash; do
    if output=$(run_cage "$CAGE" add-launcher copilot "$bad"); then
        fail "name '$bad' should be rejected" "$output"
    fi
done
if output=$(run_cage "$CAGE" remove-launcher ../other); then
    fail "slash in remove name should be rejected" "$output"
fi
echo "  PASS: unsafe names rejected"

echo "Test 17: remove-launcher refuses a foreign file"
if output=$(run_cage "$CAGE" remove-launcher other); then
    fail "remove-launcher should refuse a foreign file" "$output"
fi
[ -f "$BIN_DIR/other" ] || fail "foreign file was removed"
echo "  PASS: foreign file kept"

echo "Test 18: remove-launcher removes its own launcher"
output=$(run_cage "$CAGE" remove-launcher copilot-cage) || fail "remove-launcher failed" "$output"
[ ! -e "$BIN_DIR/copilot-cage" ] || fail "launcher still exists" "$output"
echo "  PASS: launcher removed"

echo "Test 19: remove-launcher on a missing name fails"
if output=$(run_cage "$CAGE" remove-launcher copilot-cage); then
    fail "removing a missing launcher should exit non-zero" "$output"
fi
echo "  PASS: missing launcher reported"

echo ""
echo "=== Testing launcher completions ==="
echo ""

BASH_COMP_DIR="$TEST_TMP/.local/share/bash-completion/completions"
ZSH_COMP_DIR="$TEST_TMP/.zsh/completions"

echo "Test 20: without claude-cage completions, add-launcher only hints"
output=$(run_cage "$CAGE" add-launcher copilot) || fail "add-launcher failed" "$output"
echo "$output" | grep -q "claude-cage install-completions" \
    || fail "expected install-completions hint" "$output"
[ ! -e "$BASH_COMP_DIR/copilot-cage" ] && [ ! -e "$ZSH_COMP_DIR/_copilot-cage" ] \
    || fail "no completion files should be written"
run_cage "$CAGE" remove-launcher copilot-cage >/dev/null
echo "  PASS: hint only"

mkdir -p "$BASH_COMP_DIR" "$ZSH_COMP_DIR"
echo "# installed" > "$BASH_COMP_DIR/claude-cage"
echo "# installed" > "$ZSH_COMP_DIR/_claude-cage"

echo "Test 21: add-launcher writes bash and zsh completion files"
output=$(run_cage "$CAGE" add-launcher copilot) || fail "add-launcher failed" "$output"
echo "$output" | grep -q "Tab-completion's hooked up" \
    || fail "expected completion message" "$output"
[ -f "$BASH_COMP_DIR/copilot-cage" ] || fail "bash completion file missing" "$output"
[ "$(sed -n 1p "$ZSH_COMP_DIR/_copilot-cage")" = "#compdef copilot-cage" ] \
    || fail "zsh completion should start with #compdef copilot-cage" "$(cat "$ZSH_COMP_DIR/_copilot-cage")"
echo "  PASS: completion files written"

echo "Test 22: bash completion file registers the launcher"
registered=$(bash -c 'PATH="$1:$PATH"; source "$2"; complete -p copilot-cage' \
    _ "$CAGE_DIR/dist" "$BASH_COMP_DIR/copilot-cage" 2>&1) || true
[ "$registered" = "complete -F _claude_cage copilot-cage" ] \
    || fail "expected copilot-cage registered with _claude_cage" "$registered"
echo "  PASS: launcher registered"

echo "Test 23: remove-launcher removes its completion files"
output=$(run_cage "$CAGE" remove-launcher copilot-cage) || fail "remove-launcher failed" "$output"
[ ! -e "$BASH_COMP_DIR/copilot-cage" ] && [ ! -e "$ZSH_COMP_DIR/_copilot-cage" ] \
    || fail "completion files should be removed"
echo "  PASS: completion files removed"

echo "Test 24: foreign completion files are left alone"
echo "foreign" > "$BASH_COMP_DIR/foreign-cage"
run_cage "$CAGE" add-launcher foreign >/dev/null || fail "add-launcher failed"
[ "$(cat "$BASH_COMP_DIR/foreign-cage")" = "foreign" ] \
    || fail "foreign completion file was overwritten"
run_cage "$CAGE" remove-launcher foreign-cage >/dev/null || fail "remove-launcher failed"
[ -f "$BASH_COMP_DIR/foreign-cage" ] || fail "foreign completion file was removed"
[ ! -e "$ZSH_COMP_DIR/_foreign-cage" ] || fail "own zsh completion file should be removed"
echo "  PASS: foreign completion files kept"

echo "Test 25: install-completions hooks up existing launchers"
rm -f "$BASH_COMP_DIR/claude-cage" "$ZSH_COMP_DIR/_claude-cage"
run_cage "$CAGE" add-launcher early >/dev/null || fail "add-launcher failed"
[ ! -e "$BASH_COMP_DIR/early-cage" ] || fail "no hook expected before completions exist"
echo "# installed" > "$BASH_COMP_DIR/claude-cage"
output=$(run_cage "$CAGE" install-completions) || fail "install-completions failed" "$output"
echo "$output" | grep -q "Hooked up completions for your launchers: early-cage" \
    || fail "expected existing launcher hooked" "$output"
[ -f "$BASH_COMP_DIR/early-cage" ] || fail "bash completion for early-cage missing" "$output"
echo "  PASS: existing launchers hooked"

echo "Test 26: remove-launcher cleans a stale completion file"
rm -f "$BIN_DIR/early-cage"
run_cage "$CAGE" remove-launcher early-cage >/dev/null || true
[ ! -e "$BASH_COMP_DIR/early-cage" ] || fail "stale completion file should be removed"
echo "  PASS: stale completion cleaned"

echo ""
echo "=== All launch tests passed ==="
