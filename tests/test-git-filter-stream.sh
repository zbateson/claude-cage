#!/usr/bin/env bash
# Test git-filter-stream.sh functionality
# Tests filter_fast_export_stream with various exclusion patterns

set -euo pipefail

echo "=== test-git-filter-stream.sh ==="
echo ""

CAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

# Build if needed
make -C "$CAGE_DIR" >/dev/null 2>&1 || true

# Source the built script for function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"

passed=0
total=0

# Helper: create a fresh git repo with standard config
init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init --quiet
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
}

# --------------------------------------------------------------------------
# Test 1: No patterns - passthrough
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: No patterns - stream passes through unchanged"

SRC="$TEST_TMP/test_1_src"
DST="$TEST_TMP/test_1_dst"
init_repo "$SRC"

echo "hello" > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add file" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^file\.txt$"; then
    echo "FAIL: file.txt should be present in passthrough"
    exit 1
fi

content=$(git -C "$DST" show HEAD:file.txt)
if [ "$content" != "hello" ]; then
    echo "FAIL: file content mismatch (got '$content', expected 'hello')"
    exit 1
fi
echo "  PASS: No patterns - stream passes through unchanged"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 2: Exact file exclude
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Exact file exclude"

SRC="$TEST_TMP/test_2_src"
DST="$TEST_TMP/test_2_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream ".env" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if echo "$file_list" | grep -q "^\.env$"; then
    echo "FAIL: .env should be excluded"
    exit 1
fi
echo "  PASS: Exact file exclude"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 3: Directory prefix exclude
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Directory prefix exclude (secrets/)"

SRC="$TEST_TMP/test_3_src"
DST="$TEST_TMP/test_3_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
mkdir -p "$SRC/secrets"
echo "key" > "$SRC/secrets/key.pem"
echo "cert" > "$SRC/secrets/cert.pem"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream "secrets/" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if echo "$file_list" | grep -q "^secrets/"; then
    echo "FAIL: secrets/ directory should be excluded"
    echo "Found: $(echo "$file_list" | grep '^secrets/')"
    exit 1
fi
echo "  PASS: Directory prefix exclude"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 4: Glob pattern exclude (*.log)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Glob pattern exclude (*.log)"

SRC="$TEST_TMP/test_4_src"
DST="$TEST_TMP/test_4_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
echo "log1" > "$SRC/app.log"
mkdir -p "$SRC/logs"
echo "log2" > "$SRC/logs/debug.log"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream "*.log" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if echo "$file_list" | grep -q "\.log$"; then
    echo "FAIL: .log files should be excluded"
    echo "Found: $(echo "$file_list" | grep '\.log$')"
    exit 1
fi
echo "  PASS: Glob pattern exclude"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 5: Mixed commit preservation (both excluded and non-excluded files)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Mixed commit - excluded content absent, non-excluded present"

SRC="$TEST_TMP/test_5_src"
DST="$TEST_TMP/test_5_dst"
init_repo "$SRC"

echo "initial" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial" --quiet

# Second commit touches both excluded and non-excluded
echo "updated" > "$SRC/readme.txt"
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Mixed commit" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream ".env" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if echo "$file_list" | grep -q "^\.env$"; then
    echo "FAIL: .env should be excluded"
    exit 1
fi

# Verify the non-excluded file has the updated content from the mixed commit
content=$(git -C "$DST" show HEAD:readme.txt)
if [ "$content" != "updated" ]; then
    echo "FAIL: readme.txt should have updated content (got '$content')"
    exit 1
fi
echo "  PASS: Mixed commit preservation"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 6: Exclude-only commit becomes empty (preserved for 1:1 mapping)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Exclude-only commit becomes empty but is preserved"

SRC="$TEST_TMP/test_6_src"
DST="$TEST_TMP/test_6_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial" --quiet

# Second commit touches only excluded file
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add secret only" --quiet

# Third commit touches non-excluded file
echo "more public" > "$SRC/other.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add other" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream ".env" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

# All three commits should exist in destination (1:1 mapping)
src_count=$(git -C "$SRC" rev-list --all --count)
dst_count=$(git -C "$DST" rev-list --all --count)
if [ "$src_count" != "$dst_count" ]; then
    echo "FAIL: commit count mismatch ($dst_count in dst vs $src_count in src)"
    exit 1
fi

# The second commit should be empty (no tree change from its parent)
# Get the second commit (one before HEAD)
second_commit=$(git -C "$DST" rev-parse HEAD~1)
diff_output=$(git -C "$DST" diff-tree --no-commit-id -r "$second_commit" 2>/dev/null || true)
if [ -n "$diff_output" ]; then
    echo "FAIL: second commit should be empty after filtering"
    echo "Diff: $diff_output"
    exit 1
fi
echo "  PASS: Exclude-only commit becomes empty but is preserved"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 7: Multiple patterns applied simultaneously
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Multiple exclusion patterns"

SRC="$TEST_TMP/test_7_src"
DST="$TEST_TMP/test_7_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
echo "secret" > "$SRC/.env"
echo "log" > "$SRC/app.log"
mkdir -p "$SRC/secrets"
echo "key" > "$SRC/secrets/key.pem"
echo "data" > "$SRC/data.csv"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream ".env" "*.log" "secrets/" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if ! echo "$file_list" | grep -q "^data\.csv$"; then
    echo "FAIL: data.csv should be present"
    exit 1
fi
if echo "$file_list" | grep -q "^\.env$"; then
    echo "FAIL: .env should be excluded"
    exit 1
fi
if echo "$file_list" | grep -q "\.log$"; then
    echo "FAIL: .log files should be excluded"
    exit 1
fi
if echo "$file_list" | grep -q "^secrets/"; then
    echo "FAIL: secrets/ should be excluded"
    exit 1
fi
echo "  PASS: Multiple exclusion patterns"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 8: Commit count preserved (1:1 mapping guarantee)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Commit count preserved across filter"

SRC="$TEST_TMP/test_8_src"
DST="$TEST_TMP/test_8_dst"
init_repo "$SRC"

# Create several commits, some touching excluded files, some not
echo "a" > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit 1" --quiet

echo "secret1" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit 2 (excluded only)" --quiet

echo "b" > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit 3" --quiet

echo "secret2" > "$SRC/.env"
echo "c" > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit 4 (mixed)" --quiet

echo "d" > "$SRC/file.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit 5" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream ".env" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

src_count=$(git -C "$SRC" rev-list --all --count)
dst_count=$(git -C "$DST" rev-list --all --count)
if [ "$src_count" != "$dst_count" ]; then
    echo "FAIL: commit count $dst_count in dst vs $src_count in src"
    exit 1
fi
if [ "$src_count" != "5" ]; then
    echo "FAIL: expected 5 commits in source, got $src_count"
    exit 1
fi
echo "  PASS: Commit count preserved ($src_count commits)"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 9: Quoted paths (files with spaces)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Quoted paths (files with spaces handled correctly)"

SRC="$TEST_TMP/test_9_src"
DST="$TEST_TMP/test_9_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
echo "has space" > "$SRC/my file.txt"
echo "secret" > "$SRC/my secret.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files with spaces" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream "my secret.env" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if ! echo "$file_list" | grep -q "my file\.txt"; then
    echo "FAIL: 'my file.txt' should be present"
    exit 1
fi
if echo "$file_list" | grep -q "my secret\.env"; then
    echo "FAIL: 'my secret.env' should be excluded"
    exit 1
fi
echo "  PASS: Quoted paths handled correctly"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 10: Nested directory exclude (src/__pycache__/)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Nested directory exclude (src/__pycache__/)"

SRC="$TEST_TMP/test_10_src"
DST="$TEST_TMP/test_10_dst"
init_repo "$SRC"

echo "public" > "$SRC/readme.txt"
mkdir -p "$SRC/src/__pycache__" "$SRC/src/sub/__pycache__" "$SRC/src/lib"
echo "code" > "$SRC/src/main.py"
echo "lib" > "$SRC/src/lib/utils.py"
echo "cache1" > "$SRC/src/__pycache__/main.cpython-311.pyc"
echo "cache2" > "$SRC/src/sub/__pycache__/sub.cpython-311.pyc"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add python project" --quiet

git init --bare "$DST" --quiet
git -C "$SRC" fast-export --all \
    | filter_fast_export_stream "src/__pycache__/" "src/sub/__pycache__/" \
    | git -C "$DST" fast-import --quiet 2>/dev/null

file_list=$(git -C "$DST" ls-tree -r --name-only HEAD)
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if ! echo "$file_list" | grep -q "^src/main\.py$"; then
    echo "FAIL: src/main.py should be present"
    exit 1
fi
if ! echo "$file_list" | grep -q "^src/lib/utils\.py$"; then
    echo "FAIL: src/lib/utils.py should be present"
    exit 1
fi
if echo "$file_list" | grep -q "__pycache__"; then
    echo "FAIL: __pycache__ directories should be excluded"
    echo "Found: $(echo "$file_list" | grep '__pycache__')"
    exit 1
fi
echo "  PASS: Nested directory exclude"
passed=$((passed + 1))

# ==========================================================================
# Gitignore-semantics tests (XFAIL — known gaps in pattern matching)
#
# These tests document differences between our glob matching and gitignore
# semantics. They are expected to fail until we fix the pattern engine.
#
# Reference: gitignore(5) and git's wildmatch implementation
#   - * matches anything except /
#   - ** matches anything including /
#   - ? matches one character except /
#   - Pattern without / is matched against basename at any depth
#   - **/ prefix matches zero or more directories
#   - [abc] character classes work
# ==========================================================================

xfail=0
xfail_total=0

# Helper: run a filter and capture the file list (reusable for xfail tests)
run_filter() {
    local src="$1" dst="$2"
    shift 2
    git init --bare "$dst" --quiet
    git -C "$src" fast-export --all \
        | filter_fast_export_stream "$@" \
        | git -C "$dst" fast-import --quiet 2>/dev/null
    git -C "$dst" ls-tree -r --name-only HEAD 2>/dev/null || true
}

# --------------------------------------------------------------------------
# XFAIL 1: **/ prefix should match zero directories (root-level match)
#
# In gitignore, **/__pycache__ matches __pycache__ at ANY depth including
# the repo root. Our regex ^.*/__pycache__(/.*)?$ requires at least one
# directory prefix, so root-level __pycache__ is missed.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: **/__pycache__ should match at root level"

SRC="$TEST_TMP/xfail_1_src"
DST="$TEST_TMP/xfail_1_dst"
init_repo "$SRC"

mkdir -p "$SRC/__pycache__" "$SRC/src/__pycache__"
echo "root-cache" > "$SRC/__pycache__/root.pyc"
echo "nested-cache" > "$SRC/src/__pycache__/module.pyc"
echo "code" > "$SRC/main.py"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "**/__pycache__")
_xfail_ok=true
if echo "$file_list" | grep -q "^__pycache__/"; then
    echo "  BUG: root-level __pycache__/ not excluded by **/__pycache__"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^src/__pycache__/"; then
    echo "  BUG: src/__pycache__/ not excluded by **/__pycache__"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^main\.py$"; then
    echo "  BUG: main.py should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 2: Plain name without / should match at any depth (basename match)
#
# In gitignore, a pattern without / is matched against the file's basename,
# so ".env" matches both root .env and config/.env. Our regex ^\.env(/.*)?$
# only matches at root.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: Plain name .env should match at any depth"

SRC="$TEST_TMP/xfail_2_src"
DST="$TEST_TMP/xfail_2_dst"
init_repo "$SRC"

echo "root-secret" > "$SRC/.env"
mkdir -p "$SRC/config" "$SRC/deploy/staging"
echo "config-secret" > "$SRC/config/.env"
echo "staging-secret" > "$SRC/deploy/staging/.env"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" ".env")
_xfail_ok=true
if echo "$file_list" | grep -q "^\.env$"; then
    echo "  BUG: root .env not excluded"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^config/\.env$"; then
    echo "  BUG: config/.env not excluded by plain .env pattern"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^deploy/staging/\.env$"; then
    echo "  BUG: deploy/staging/.env not excluded by plain .env pattern"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "  BUG: readme.txt should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 3: * should not cross / when pattern contains /
#
# In gitignore, dir/*.log matches dir/app.log but NOT dir/sub/app.log
# because * does not cross directory separators. Our regex dir/.*\.log
# matches both because .* crosses /.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: dir/*.log should not match dir/sub/app.log"

SRC="$TEST_TMP/xfail_3_src"
DST="$TEST_TMP/xfail_3_dst"
init_repo "$SRC"

mkdir -p "$SRC/dir/sub"
echo "direct" > "$SRC/dir/app.log"
echo "nested" > "$SRC/dir/sub/app.log"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "dir/*.log")
_xfail_ok=true
if echo "$file_list" | grep -q "^dir/app\.log$"; then
    echo "  BUG: dir/app.log should be excluded by dir/*.log"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^dir/sub/app\.log$"; then
    echo "  BUG: dir/sub/app.log should NOT be excluded by dir/*.log (* doesn't cross /)"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "  BUG: readme.txt should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 4: **/ should match zero or more directories
#
# **/foo.txt should match foo.txt at root (zero directories) AND
# dir/foo.txt, a/b/foo.txt, etc. Our regex ^.*/foo\.txt(/.*)?$ requires
# at least one directory level, missing root.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: **/foo.txt should match root-level foo.txt"

SRC="$TEST_TMP/xfail_4_src"
DST="$TEST_TMP/xfail_4_dst"
init_repo "$SRC"

echo "root-secret" > "$SRC/foo.txt"
mkdir -p "$SRC/dir" "$SRC/a/b"
echo "dir-secret" > "$SRC/dir/foo.txt"
echo "deep-secret" > "$SRC/a/b/foo.txt"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "**/foo.txt")
_xfail_ok=true
if echo "$file_list" | grep -q "^foo\.txt$"; then
    echo "  BUG: root foo.txt not excluded by **/foo.txt"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^dir/foo\.txt$"; then
    echo "  BUG: dir/foo.txt not excluded by **/foo.txt"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^a/b/foo\.txt$"; then
    echo "  BUG: a/b/foo.txt not excluded by **/foo.txt"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "  BUG: readme.txt should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 5: Plain directory name should match at any depth
#
# __pycache__ (no / in pattern) should match __pycache__ at any depth,
# like gitignore basename matching. Currently only matches root.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: Plain __pycache__ should match at any depth"

SRC="$TEST_TMP/xfail_5_src"
DST="$TEST_TMP/xfail_5_dst"
init_repo "$SRC"

mkdir -p "$SRC/__pycache__" "$SRC/src/__pycache__" "$SRC/src/deep/__pycache__"
echo "root" > "$SRC/__pycache__/root.pyc"
echo "src" > "$SRC/src/__pycache__/module.pyc"
echo "deep" > "$SRC/src/deep/__pycache__/deep.pyc"
echo "code" > "$SRC/main.py"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "__pycache__")
_xfail_ok=true
if echo "$file_list" | grep -q "__pycache__"; then
    echo "  BUG: __pycache__ found in output: $(echo "$file_list" | grep '__pycache__' | head -3)"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^main\.py$"; then
    echo "  BUG: main.py should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 6: *.ext without / should match at any depth (basename semantics)
#
# In gitignore, *.log (no /) matches the basename, so it excludes
# app.log AND dir/debug.log AND deep/nested/trace.log. Our current
# implementation happens to get this right (*.log → ^.*\.log(/.*)?$),
# but for the WRONG reason (* crosses / in our regex). This test
# verifies the behavior works, but also tests that a similar pattern
# WITH a / component (logs/*.log) correctly restricts depth.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: logs/*.log should not match logs/sub/deep.log"

SRC="$TEST_TMP/xfail_6_src"
DST="$TEST_TMP/xfail_6_dst"
init_repo "$SRC"

mkdir -p "$SRC/logs/sub"
echo "direct" > "$SRC/logs/app.log"
echo "nested" > "$SRC/logs/sub/deep.log"
echo "root" > "$SRC/app.log"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "logs/*.log")
_xfail_ok=true
if echo "$file_list" | grep -q "^logs/app\.log$"; then
    echo "  BUG: logs/app.log should be excluded by logs/*.log"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^logs/sub/deep\.log$"; then
    echo "  BUG: logs/sub/deep.log should NOT be excluded by logs/*.log (* doesn't cross /)"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^app\.log$"; then
    echo "  BUG: root app.log should NOT be excluded by logs/*.log (has / so full-path match)"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

# --------------------------------------------------------------------------
# XFAIL 7: dir/**/file should match dir/file (zero intermediate dirs)
#
# In gitignore, dir/**/file.txt matches dir/file.txt (zero intermediate
# directories), dir/a/file.txt, dir/a/b/file.txt, etc.
# --------------------------------------------------------------------------
xfail_total=$((xfail_total + 1))
echo "XFAIL $xfail_total: dir/**/file.txt should match dir/file.txt (zero intermediate)"

SRC="$TEST_TMP/xfail_7_src"
DST="$TEST_TMP/xfail_7_dst"
init_repo "$SRC"

mkdir -p "$SRC/dir/a/b"
echo "direct" > "$SRC/dir/file.txt"
echo "one-deep" > "$SRC/dir/a/file.txt"
echo "two-deep" > "$SRC/dir/a/b/file.txt"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_filter "$SRC" "$DST" "dir/**/file.txt")
_xfail_ok=true
if echo "$file_list" | grep -q "^dir/file\.txt$"; then
    echo "  BUG: dir/file.txt not excluded by dir/**/file.txt (zero intermediate)"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^dir/a/file\.txt$"; then
    echo "  BUG: dir/a/file.txt not excluded by dir/**/file.txt"
    _xfail_ok=false
fi
if echo "$file_list" | grep -q "^dir/a/b/file\.txt$"; then
    echo "  BUG: dir/a/b/file.txt not excluded by dir/**/file.txt"
    _xfail_ok=false
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "  BUG: readme.txt should be present"
    _xfail_ok=false
fi
if $_xfail_ok; then
    echo "  SURPRISE PASS (fixed?)"
    passed=$((passed + 1))
else
    echo "  XFAIL (expected)"
    xfail=$((xfail + 1))
fi

echo ""
echo "Results: $passed/$total passed, $xfail/$xfail_total xfail (expected failures)"
[ $passed -eq $total ] || exit 1
