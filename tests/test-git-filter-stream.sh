#!/usr/bin/env bash
# Test :(exclude,glob) pathspec filtering on git fast-export
# Tests that exclude patterns correctly filter files via pathspec

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

# Helper: run fast-export with pathspec excludes and capture file list
# Arguments: $1=src $2=dst, remaining args are raw exclude patterns (not pathspecs)
run_export() {
    local src="$1" dst="$2"
    shift 2
    git init --bare "$dst" --quiet

    # Build pathspec args using the same logic as build_exclude_pathspecs
    local -a exclude_args=()
    local pat pathspec base
    for pat in "$@"; do
        if [[ "$pat" == */* ]]; then
            pathspec="$pat"
        else
            pathspec="**/$pat"
        fi
        exclude_args+=(":(exclude,glob)$pathspec")
        # Add /** variant to match files inside matching directories
        base="${pathspec%/}"
        base="${base%/\*}"
        exclude_args+=(":(exclude,glob)${base}/**")
    done

    git -C "$src" fast-export --all \
        ${exclude_args:+-- "${exclude_args[@]}"} \
        2>/dev/null \
        | git -C "$dst" fast-import --quiet 2>/dev/null
    git -C "$dst" ls-tree -r --name-only HEAD 2>/dev/null || true
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
git -C "$SRC" fast-export --all 2>/dev/null \
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

file_list=$(run_export "$SRC" "$DST" ".env")
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

file_list=$(run_export "$SRC" "$DST" "secrets/")
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

file_list=$(run_export "$SRC" "$DST" "*.log")
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

file_list=$(run_export "$SRC" "$DST" ".env")
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
# Test 6: Exclude-only commit is dropped by fast-export (no tree change)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Exclude-only commit dropped (fewer commits in dest)"

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

file_list=$(run_export "$SRC" "$DST" ".env")

# fast-export with pathspec drops commits that become empty
# Source has 3 commits, but dest should have 2 (exclude-only commit dropped)
src_count=$(git -C "$SRC" rev-list --all --count)
dst_count=$(git -C "$DST" rev-list --all --count)
if [ "$src_count" != "3" ]; then
    echo "FAIL: expected 3 commits in source, got $src_count"
    exit 1
fi
if [ "$dst_count" != "2" ]; then
    echo "FAIL: expected 2 commits in dest (exclude-only dropped), got $dst_count"
    exit 1
fi

# Verify content is correct
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
if ! echo "$file_list" | grep -q "^other\.txt$"; then
    echo "FAIL: other.txt should be present"
    exit 1
fi
echo "  PASS: Exclude-only commit dropped ($src_count source -> $dst_count dest)"
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

file_list=$(run_export "$SRC" "$DST" ".env" "*.log" "secrets/")
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
# Test 8: Commit count preserved for non-excluded-only commits
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Commit count preserved for commits with non-excluded content"

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

file_list=$(run_export "$SRC" "$DST" ".env")

src_count=$(git -C "$SRC" rev-list --all --count)
dst_count=$(git -C "$DST" rev-list --all --count)
# Source has 5, dest should have 4 (Commit 2 is excluded-only, gets dropped)
if [ "$src_count" != "5" ]; then
    echo "FAIL: expected 5 commits in source, got $src_count"
    exit 1
fi
if [ "$dst_count" != "4" ]; then
    echo "FAIL: expected 4 commits in dest (1 excluded-only dropped), got $dst_count"
    exit 1
fi
echo "  PASS: Commit count correct ($src_count source -> $dst_count dest, 1 excluded-only dropped)"
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

file_list=$(run_export "$SRC" "$DST" "my secret.env")
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

file_list=$(run_export "$SRC" "$DST" "src/__pycache__/" "src/sub/__pycache__/")
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
# Gitignore-semantics tests (previously XFAIL — now using :(exclude,glob))
#
# With :(exclude,glob) pathspec + **/ prefix for slash-free patterns,
# git's wildmatch engine handles all these correctly.
# ==========================================================================

# --------------------------------------------------------------------------
# Test 11: **/__pycache__ matches at root and nested levels
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: **/__pycache__ matches at root level and nested"

SRC="$TEST_TMP/test_11_src"
DST="$TEST_TMP/test_11_dst"
init_repo "$SRC"

mkdir -p "$SRC/__pycache__" "$SRC/src/__pycache__"
echo "root-cache" > "$SRC/__pycache__/root.pyc"
echo "nested-cache" > "$SRC/src/__pycache__/module.pyc"
echo "code" > "$SRC/main.py"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "**/__pycache__")
if echo "$file_list" | grep -q "__pycache__"; then
    echo "FAIL: __pycache__ should be excluded at all depths"
    echo "Found: $(echo "$file_list" | grep '__pycache__')"
    exit 1
fi
if ! echo "$file_list" | grep -q "^main\.py$"; then
    echo "FAIL: main.py should be present"
    exit 1
fi
echo "  PASS: **/__pycache__ excludes at all depths"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 12: Plain name .env matches at any depth (basename matching via **/)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Plain name .env matches at any depth"

SRC="$TEST_TMP/test_12_src"
DST="$TEST_TMP/test_12_dst"
init_repo "$SRC"

echo "root-secret" > "$SRC/.env"
mkdir -p "$SRC/config" "$SRC/deploy/staging"
echo "config-secret" > "$SRC/config/.env"
echo "staging-secret" > "$SRC/deploy/staging/.env"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" ".env")
if echo "$file_list" | grep -q "\.env$"; then
    echo "FAIL: .env files should be excluded at all depths"
    echo "Found: $(echo "$file_list" | grep '\.env$')"
    exit 1
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
echo "  PASS: Plain name .env matches at any depth"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 13: dir/*.log should not match dir/sub/app.log (* stops at /)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: dir/*.log should not match dir/sub/app.log"

SRC="$TEST_TMP/test_13_src"
DST="$TEST_TMP/test_13_dst"
init_repo "$SRC"

mkdir -p "$SRC/dir/sub"
echo "direct" > "$SRC/dir/app.log"
echo "nested" > "$SRC/dir/sub/app.log"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "dir/*.log")
if echo "$file_list" | grep -q "^dir/app\.log$"; then
    echo "FAIL: dir/app.log should be excluded by dir/*.log"
    exit 1
fi
if ! echo "$file_list" | grep -q "^dir/sub/app\.log$"; then
    echo "FAIL: dir/sub/app.log should NOT be excluded by dir/*.log (* doesn't cross /)"
    exit 1
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
echo "  PASS: dir/*.log correctly stops at directory boundary"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 14: **/foo.txt matches root-level foo.txt (zero directories)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: **/foo.txt matches root-level foo.txt"

SRC="$TEST_TMP/test_14_src"
DST="$TEST_TMP/test_14_dst"
init_repo "$SRC"

echo "root-secret" > "$SRC/foo.txt"
mkdir -p "$SRC/dir" "$SRC/a/b"
echo "dir-secret" > "$SRC/dir/foo.txt"
echo "deep-secret" > "$SRC/a/b/foo.txt"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "**/foo.txt")
if echo "$file_list" | grep -q "foo\.txt$"; then
    echo "FAIL: foo.txt should be excluded at all depths"
    echo "Found: $(echo "$file_list" | grep 'foo\.txt$')"
    exit 1
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
echo "  PASS: **/foo.txt excludes at all depths"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 15: Plain __pycache__ matches at any depth (no-slash basename match)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Plain __pycache__ matches at any depth"

SRC="$TEST_TMP/test_15_src"
DST="$TEST_TMP/test_15_dst"
init_repo "$SRC"

mkdir -p "$SRC/__pycache__" "$SRC/src/__pycache__" "$SRC/src/deep/__pycache__"
echo "root" > "$SRC/__pycache__/root.pyc"
echo "src" > "$SRC/src/__pycache__/module.pyc"
echo "deep" > "$SRC/src/deep/__pycache__/deep.pyc"
echo "code" > "$SRC/main.py"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "__pycache__")
if echo "$file_list" | grep -q "__pycache__"; then
    echo "FAIL: __pycache__ found in output: $(echo "$file_list" | grep '__pycache__' | head -3)"
    exit 1
fi
if ! echo "$file_list" | grep -q "^main\.py$"; then
    echo "FAIL: main.py should be present"
    exit 1
fi
echo "  PASS: Plain __pycache__ matches at any depth"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 16: logs/*.log should not match logs/sub/deep.log
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: logs/*.log should not match logs/sub/deep.log"

SRC="$TEST_TMP/test_16_src"
DST="$TEST_TMP/test_16_dst"
init_repo "$SRC"

mkdir -p "$SRC/logs/sub"
echo "direct" > "$SRC/logs/app.log"
echo "nested" > "$SRC/logs/sub/deep.log"
echo "root" > "$SRC/app.log"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "logs/*.log")
if echo "$file_list" | grep -q "^logs/app\.log$"; then
    echo "FAIL: logs/app.log should be excluded by logs/*.log"
    exit 1
fi
if ! echo "$file_list" | grep -q "^logs/sub/deep\.log$"; then
    echo "FAIL: logs/sub/deep.log should NOT be excluded by logs/*.log (* doesn't cross /)"
    exit 1
fi
if ! echo "$file_list" | grep -q "^app\.log$"; then
    echo "FAIL: root app.log should NOT be excluded by logs/*.log (has / so full-path match)"
    exit 1
fi
echo "  PASS: logs/*.log correctly stops at directory boundary"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 17: dir/**/file.txt matches dir/file.txt (zero intermediate dirs)
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: dir/**/file.txt matches dir/file.txt (zero intermediate)"

SRC="$TEST_TMP/test_17_src"
DST="$TEST_TMP/test_17_dst"
init_repo "$SRC"

mkdir -p "$SRC/dir/a/b"
echo "direct" > "$SRC/dir/file.txt"
echo "one-deep" > "$SRC/dir/a/file.txt"
echo "two-deep" > "$SRC/dir/a/b/file.txt"
echo "public" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add files" --quiet

file_list=$(run_export "$SRC" "$DST" "dir/**/file.txt")
if echo "$file_list" | grep -q "^dir/.*file\.txt$"; then
    echo "FAIL: dir/**/file.txt should exclude all file.txt under dir/"
    echo "Found: $(echo "$file_list" | grep 'file\.txt$')"
    exit 1
fi
if ! echo "$file_list" | grep -q "^readme\.txt$"; then
    echo "FAIL: readme.txt should be present"
    exit 1
fi
echo "  PASS: dir/**/file.txt matches at all depths under dir/"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 18: build_exclude_pathspecs() helper produces correct output
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: build_exclude_pathspecs() helper produces correct pathspecs"

output=$(build_exclude_pathspecs ".env|*.log|__pycache__|secrets/|config/prod.yml")
expected=":(exclude,glob)**/.env
:(exclude,glob)**/.env/**
:(exclude,glob)**/*.log
:(exclude,glob)**/*.log/**
:(exclude,glob)**/__pycache__
:(exclude,glob)**/__pycache__/**
:(exclude,glob)secrets/
:(exclude,glob)secrets/**
:(exclude,glob)config/prod.yml
:(exclude,glob)config/prod.yml/**"

if [ "$output" != "$expected" ]; then
    echo "FAIL: build_exclude_pathspecs output mismatch"
    echo "Expected:"
    echo "$expected"
    echo "Got:"
    echo "$output"
    exit 1
fi
echo "  PASS: build_exclude_pathspecs() produces correct output"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 19: build_exclude_pathspecs() with empty input
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: build_exclude_pathspecs() with empty input"

output=$(build_exclude_pathspecs "")
if [ -n "$output" ]; then
    echo "FAIL: build_exclude_pathspecs should produce no output for empty input"
    echo "Got: '$output'"
    exit 1
fi
echo "  PASS: build_exclude_pathspecs() empty input"
passed=$((passed + 1))

# ==========================================================================
# Incremental (post-commit hook) tests
#
# These test the --import-marks + -1 HEAD path used by the source post-commit
# hook, not the --all path used during initial clone.
# ==========================================================================

# Helper: run incremental fast-export/import for a single commit
# Uses temp-file approach matching the real post-commit hook: export to file,
# detect excluded-only commits (missing 'commit' or 'from' line), skip fast-import.
# Returns 0=imported, 1=excluded-only (skipped), 2=error
# Arguments: $1=src $2=dst $3=source_marks $4=import_marks, remaining=raw patterns
run_incremental() {
    local src="$1" dst="$2" sm="$3" im="$4"
    shift 4

    local -a exclude_args=()
    local pat pathspec base
    for pat in "$@"; do
        if [[ "$pat" == */* ]]; then
            pathspec="$pat"
        else
            pathspec="**/$pat"
        fi
        exclude_args+=(":(exclude,glob)$pathspec")
        base="${pathspec%/}"
        base="${base%/\*}"
        exclude_args+=(":(exclude,glob)${base}/**")
    done

    local export_out="$TEST_TMP/incremental-export-out"
    git -C "$src" fast-export \
        --import-marks="$sm" --export-marks="$sm" \
        -1 HEAD \
        ${exclude_args:+-- "${exclude_args[@]}"} \
        >"$export_out" 2>/dev/null

    # Detect excluded-only: missing commit line or missing from line
    if ! grep -q '^commit ' "$export_out" || ! grep -q '^from ' "$export_out"; then
        rm -f "$export_out"
        return 1
    fi

    git -C "$dst" fast-import \
        --import-marks="$im" --export-marks="$im" \
        --quiet <"$export_out" 2>/dev/null
    local rc=$?
    rm -f "$export_out"
    return $rc
}

# --------------------------------------------------------------------------
# Test 20: Incremental mixed commit preserves all non-excluded files
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Incremental mixed commit preserves all non-excluded files"

SRC="$TEST_TMP/test_20_src"
DST="$TEST_TMP/test_20_dst"
SM="$TEST_TMP/test_20_dst/source-marks"
IM="$TEST_TMP/test_20_dst/import-marks"
init_repo "$SRC"

echo "readme" > "$SRC/readme.txt"
echo "app" > "$SRC/app.js"
echo "style" > "$SRC/style.css"
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial" --quiet

# Initial clone
run_export "$SRC" "$DST" ".env"
# Save marks (run_export uses --all without marks, need to redo with marks)
rm -rf "$DST"
git init --bare "$DST" --quiet
local_args=(":(exclude,glob)**/.env" ":(exclude,glob)**/.env/**")
git -C "$SRC" fast-export --export-marks="$SM" --all \
    -- "${local_args[@]}" 2>/dev/null \
    | git -C "$DST" fast-import --export-marks="$IM" --quiet 2>/dev/null

# Mixed commit: change .env + app.js (readme.txt and style.css unchanged)
echo "secret2" > "$SRC/.env"
echo "app updated" > "$SRC/app.js"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Mixed" --quiet

run_incremental "$SRC" "$DST" "$SM" "$IM" ".env"

# All 3 non-excluded files must survive
for f in readme.txt app.js style.css; do
    if ! git -C "$DST" show "HEAD:$f" >/dev/null 2>&1; then
        echo "FAIL: $f missing from intermediary after mixed commit"
        exit 1
    fi
done
content=$(git -C "$DST" show HEAD:app.js)
if [ "$content" != "app updated" ]; then
    echo "FAIL: app.js content should be updated (got '$content')"
    exit 1
fi
echo "  PASS: Incremental mixed commit preserves all non-excluded files"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 21: Incremental after excluded-only commit preserves all files
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Incremental mixed commit after excluded-only gap"

SRC="$TEST_TMP/test_21_src"
DST="$TEST_TMP/test_21_dst"
SM="$TEST_TMP/test_21_dst/source-marks"
IM="$TEST_TMP/test_21_dst/import-marks"
init_repo "$SRC"

echo "readme" > "$SRC/readme.txt"
echo "app" > "$SRC/app.js"
echo "style" > "$SRC/style.css"
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial" --quiet

# Initial clone with marks
git init --bare "$DST" --quiet
local_args=(":(exclude,glob)**/.env" ":(exclude,glob)**/.env/**")
git -C "$SRC" fast-export --export-marks="$SM" --all \
    -- "${local_args[@]}" 2>/dev/null \
    | git -C "$DST" fast-import --export-marks="$IM" --quiet 2>/dev/null

# Excluded-only commit (creates marks gap — run_incremental returns 1)
echo "secret2" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Excluded only" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env" || true

# Mixed commit after the gap
echo "secret3" > "$SRC/.env"
echo "readme updated" > "$SRC/readme.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Mixed after gap" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env"

# All 3 non-excluded files must survive (especially app.js and style.css)
for f in readme.txt app.js style.css; do
    if ! git -C "$DST" show "HEAD:$f" >/dev/null 2>&1; then
        echo "FAIL: $f missing from intermediary after mixed commit following excluded-only gap"
        exit 1
    fi
done
content=$(git -C "$DST" show HEAD:readme.txt)
if [ "$content" != "readme updated" ]; then
    echo "FAIL: readme.txt content should be updated (got '$content')"
    exit 1
fi
if git -C "$DST" show HEAD:.env >/dev/null 2>&1; then
    echo "FAIL: .env should not be in intermediary"
    exit 1
fi
echo "  PASS: Incremental mixed commit after excluded-only gap preserves files"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 22: Multiple incremental commits in sequence
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Multiple incremental commits in sequence"

SRC="$TEST_TMP/test_22_src"
DST="$TEST_TMP/test_22_dst"
SM="$TEST_TMP/test_22_dst/source-marks"
IM="$TEST_TMP/test_22_dst/import-marks"
init_repo "$SRC"

echo "file1" > "$SRC/file1.txt"
echo "secret" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial" --quiet

git init --bare "$DST" --quiet
local_args=(":(exclude,glob)**/.env" ":(exclude,glob)**/.env/**")
git -C "$SRC" fast-export --export-marks="$SM" --all \
    -- "${local_args[@]}" 2>/dev/null \
    | git -C "$DST" fast-import --export-marks="$IM" --quiet 2>/dev/null

# Commit 2: add new non-excluded file
echo "file2" > "$SRC/file2.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add file2" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env"

# Commit 3: excluded-only (run_incremental returns 1)
echo "secret2" > "$SRC/.env"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Secret only" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env" || true

# Commit 4: mixed
echo "secret3" > "$SRC/.env"
echo "file1 updated" > "$SRC/file1.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Mixed" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env"

# Commit 5: normal
echo "file3" > "$SRC/file3.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Add file3" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" ".env"

# Verify final state
dst_count=$(git -C "$DST" rev-list --all --count)
# 5 source commits, 1 excluded-only dropped = 4 in dest
if [ "$dst_count" != "4" ]; then
    echo "FAIL: expected 4 commits in dest, got $dst_count"
    exit 1
fi
for f in file1.txt file2.txt file3.txt; do
    if ! git -C "$DST" show "HEAD:$f" >/dev/null 2>&1; then
        echo "FAIL: $f missing"
        exit 1
    fi
done
content=$(git -C "$DST" show HEAD:file1.txt)
if [ "$content" != "file1 updated" ]; then
    echo "FAIL: file1.txt should be updated"
    exit 1
fi
if git -C "$DST" show HEAD:.env >/dev/null 2>&1; then
    echo "FAIL: .env should not be in dest"
    exit 1
fi
echo "  PASS: Multiple incremental commits in sequence"
passed=$((passed + 1))

# --------------------------------------------------------------------------
# Test 23: Excluded-only NEW file on large repo (reproduces orphan root bug)
#
# On repos with many files, an excluded-only commit causes fast-export to emit
# an orphan root commit (no 'from' line) instead of a reset, because
# --export-marks only writes commit marks (blob marks are lost). The temp-file
# approach in run_incremental detects this and skips fast-import.
# --------------------------------------------------------------------------
total=$((total + 1))
echo "Test $total: Excluded-only new file on large repo detected correctly"

SRC="$TEST_TMP/test_23_src"
DST="$TEST_TMP/test_23_dst"
SM="$TEST_TMP/test_23_dst/source-marks"
IM="$TEST_TMP/test_23_dst/import-marks"
init_repo "$SRC"

# Create a repo with enough files that fast-export won't optimize to a reset
mkdir -p "$SRC/src" "$SRC/tests" "$SRC/config" "$SRC/docs"
for i in $(seq 1 50); do
    echo "module $i code" > "$SRC/src/module${i}.php"
    echo "test $i code" > "$SRC/tests/test${i}.php"
done
echo "readme" > "$SRC/README.md"
echo "composer" > "$SRC/composer.json"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Initial large repo" --quiet

# Build ~30 commits of history
for i in $(seq 2 30); do
    file_num=$(( (i % 50) + 1 ))
    echo "update $i" >> "$SRC/src/module${file_num}.php"
    git -C "$SRC" add -A && git -C "$SRC" commit -m "Commit $i" --quiet
done

# Initial clone with marks
git init --bare "$DST" --quiet
local_args=(":(exclude,glob)**/application-*.properties" ":(exclude,glob)**/application-*.properties/**")
git -C "$SRC" fast-export --export-marks="$SM" --all \
    -- "${local_args[@]}" 2>/dev/null \
    | git -C "$DST" fast-import --export-marks="$IM" --quiet 2>/dev/null

dst_before=$(git -C "$DST" rev-parse HEAD)

# Mixed commit (to advance marks)
echo "new content" > "$SRC/TESTFILE.txt"
echo "secret" > "$SRC/application-test.properties"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Mixed commit" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" "application-*.properties"

# Excluded-only commit: add a NEW excluded file
echo "blah config" > "$SRC/application-blah.properties"
git -C "$SRC" add application-blah.properties
git -C "$SRC" commit -m "Just an ignored file" --quiet

# This is the critical test: run_incremental should return 1 (excluded-only)
# NOT 2 (fast-import error), and should NOT corrupt the intermediary
incr_rc=0
run_incremental "$SRC" "$DST" "$SM" "$IM" "application-*.properties" || incr_rc=$?

if [ "$incr_rc" -ne 1 ]; then
    echo "FAIL: expected run_incremental to return 1 (excluded-only), got $incr_rc"
    exit 1
fi

# Verify intermediary is still intact (TESTFILE.txt from mixed commit present)
if ! git -C "$DST" show HEAD:TESTFILE.txt >/dev/null 2>&1; then
    echo "FAIL: TESTFILE.txt should still be in intermediary"
    exit 1
fi

# Verify excluded file is NOT in intermediary
if git -C "$DST" show HEAD:application-test.properties >/dev/null 2>&1; then
    echo "FAIL: application-test.properties should not be in intermediary"
    exit 1
fi
if git -C "$DST" show HEAD:application-blah.properties >/dev/null 2>&1; then
    echo "FAIL: application-blah.properties should not be in intermediary"
    exit 1
fi

# Verify a subsequent normal commit still works
echo "another file" > "$SRC/ANOTHER.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -m "Normal after excluded-only" --quiet
run_incremental "$SRC" "$DST" "$SM" "$IM" "application-*.properties"

if ! git -C "$DST" show HEAD:ANOTHER.txt >/dev/null 2>&1; then
    echo "FAIL: ANOTHER.txt should be in intermediary after normal commit"
    exit 1
fi
echo "  PASS: Excluded-only new file on large repo detected and skipped"
passed=$((passed + 1))

echo ""
echo "Results: $passed/$total passed"
[ $passed -eq $total ] || exit 1
