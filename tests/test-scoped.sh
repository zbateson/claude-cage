#!/bin/bash
# Test scoped intermediary functionality
# Tests --scoped flag: scoped fast-export, metadata files, repos.list,
# scoped hook, and mount logic

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

echo "=== Testing scoped intermediary ==="
echo ""

# Source the built script for direct function access
export CLAUDE_CAGE_SOURCING=1
source "$CAGE_DIR/dist/claude-cage"
unset CLAUDE_CAGE_SOURCING

# Create a test git repo with subdirectory structure
mkdir -p "$TEST_TMP/monorepo"
cd "$TEST_TMP/monorepo"
git init
git config user.email "test@test.com"
git config user.name "Test"

# Create files in multiple service directories
mkdir -p services/api services/web shared
echo "api readme" > services/api/README.md
echo "api app" > services/api/app.go
echo "web readme" > services/web/README.md
echo "web index" > services/web/index.html
echo "shared lib" > shared/lib.go
echo "root readme" > README.md
echo "secret" > .env
git add -A && git commit -m "Initial monorepo structure"

# Second commit - touch only services/api
echo "api v2" > services/api/app.go
git add -A && git commit -m "Update API app"

# Third commit - touch only services/web
echo "web v2" > services/web/index.html
git add -A && git commit -m "Update web index"

# Fourth commit - touch both
echo "shared v2" > shared/lib.go
echo "api v3" > services/api/app.go
git add -A && git commit -m "Update shared and API"

MONOREPO_PATH="$TEST_TMP/monorepo"
SOURCE_API="$MONOREPO_PATH/services/api"
GIT_ROOT="$MONOREPO_PATH"
BRANCH_NAME=$(git -C "$MONOREPO_PATH" branch --show-current)

echo "=== Testing scope helpers ==="
echo ""

echo "Test 1: get_scope_path() from git root returns empty"
result=$(get_scope_path "$MONOREPO_PATH")
if [ -n "$result" ]; then
    echo "FAIL: Expected empty scope_path at git root, got '$result'"
    exit 1
fi
echo "  PASS: get_scope_path at root is empty"

echo "Test 2: get_scope_path() from subdirectory returns relative path"
result=$(get_scope_path "$SOURCE_API")
if [ "$result" != "services/api" ]; then
    echo "FAIL: Expected 'services/api', got '$result'"
    exit 1
fi
echo "  PASS: get_scope_path returns 'services/api'"

echo "Test 3: get_git_root_hash() returns consistent 12-char hash"
hash1=$(get_git_root_hash "$SOURCE_API")
hash2=$(get_git_root_hash "$MONOREPO_PATH")
if [ "$hash1" != "$hash2" ]; then
    echo "FAIL: Hash from subdir ($hash1) differs from root ($hash2)"
    exit 1
fi
if [ ${#hash1} -ne 12 ]; then
    echo "FAIL: Hash length is ${#hash1}, expected 12"
    exit 1
fi
echo "  PASS: get_git_root_hash is consistent and 12 chars"

echo ""
echo "=== Testing scoped intermediary creation ==="
echo ""

# Set variables needed by create_intermediary_clone
SESSION_ID="test-scoped"
CLAUDE_CAGE_SESSION="$SESSION_ID"
export CLAUDE_CAGE_SESSION
cfg_exclude=".env"
cfg_git_historyDepth=50
cfg_git_defaultBranch="auto"
dry_run=false
verbose=false

INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
WORK_DIR=$(get_work_path "$SOURCE_API")

echo "Test 4: Scoped intermediary has stripped paths (no scope prefix)"
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

tree_listing=$(git -C "$INTERMEDIARY_DIR" ls-tree -r --name-only HEAD)

# Should have stripped paths: app.go, README.md (NOT services/api/app.go)
if ! echo "$tree_listing" | grep -q "^app.go$"; then
    echo "FAIL: Expected stripped path 'app.go' in intermediary"
    echo "Tree listing:"
    echo "$tree_listing"
    exit 1
fi
echo "  PASS: app.go has stripped path"

if ! echo "$tree_listing" | grep -q "^README.md$"; then
    echo "FAIL: Expected stripped path 'README.md' in intermediary"
    echo "Tree listing:"
    echo "$tree_listing"
    exit 1
fi
echo "  PASS: README.md has stripped path"

# Should NOT have full paths with scope prefix
if echo "$tree_listing" | grep -q "^services/"; then
    echo "FAIL: Intermediary should NOT have services/ prefix (paths should be stripped)"
    echo "Tree listing:"
    echo "$tree_listing"
    exit 1
fi
echo "  PASS: No services/ prefix in intermediary"

# Should NOT have out-of-scope files
if echo "$tree_listing" | grep -q "shared/\|index.html"; then
    echo "FAIL: Out-of-scope files should NOT be in scoped intermediary"
    echo "Tree listing:"
    echo "$tree_listing"
    exit 1
fi
echo "  PASS: Out-of-scope files excluded"

# Should NOT have .env (excluded by cfg_exclude)
if echo "$tree_listing" | grep -q "\.env"; then
    echo "FAIL: .env should be excluded by cfg_exclude"
    exit 1
fi
echo "  PASS: .env is excluded by cfg_exclude"

echo ""
echo "Test 5: Metadata files written correctly"

scope_file="$INTERMEDIARY_DIR/claude-cage-scope-path"
if [ ! -f "$scope_file" ]; then
    echo "FAIL: claude-cage-scope-path not found"
    exit 1
fi
scope_val=$(cat "$scope_file")
if [ "$scope_val" != "services/api" ]; then
    echo "FAIL: scope-path should be 'services/api', got '$scope_val'"
    exit 1
fi
echo "  PASS: claude-cage-scope-path = 'services/api'"

git_root_file="$INTERMEDIARY_DIR/claude-cage-git-root"
if [ ! -f "$git_root_file" ]; then
    echo "FAIL: claude-cage-git-root not found"
    exit 1
fi
git_root_val=$(cat "$git_root_file")
if [ "$git_root_val" != "$GIT_ROOT" ]; then
    echo "FAIL: git-root should be '$GIT_ROOT', got '$git_root_val'"
    exit 1
fi
echo "  PASS: claude-cage-git-root = '$GIT_ROOT'"

exclude_ps_file="$INTERMEDIARY_DIR/claude-cage-exclude-pathspecs"
if [ ! -f "$exclude_ps_file" ]; then
    echo "FAIL: claude-cage-exclude-pathspecs not found"
    exit 1
fi
if ! grep -q "exclude,glob" "$exclude_ps_file"; then
    echo "FAIL: exclude-pathspecs should contain :(exclude,glob) entries"
    cat "$exclude_ps_file"
    exit 1
fi
echo "  PASS: claude-cage-exclude-pathspecs written"

echo ""
echo "Test 6: Commit mapping handles scoped commits correctly"
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"
if [ ! -f "$commit_map" ]; then
    echo "FAIL: Commit map not found"
    exit 1
fi

# The "Update web index" commit only touches services/web/ and should map to 0
web_only_hash=$(git -C "$MONOREPO_PATH" log --oneline --all --format="%H %s" | grep "Update web index" | awk '{print $1}')
if [ -n "$web_only_hash" ]; then
    if grep -q "^0 ${web_only_hash}$" "$commit_map" 2>/dev/null; then
        echo "  PASS: Out-of-scope-only commit mapped to 0"
    else
        # It might be completely dropped (not in rev range at all)
        if grep -q " ${web_only_hash}$" "$commit_map" 2>/dev/null; then
            echo "FAIL: Out-of-scope-only commit should map to 0, but got a real mapping"
            exit 1
        else
            echo "  PASS: Out-of-scope-only commit dropped (not in range)"
        fi
    fi
fi

echo ""
echo "=== Testing repos.list management ==="
echo ""

echo "Test 7: repos_list_add creates entry"
repos_file=$(get_repos_list_path "$SOURCE_API")
if [ ! -f "$repos_file" ]; then
    echo "FAIL: repos.list file not created by create_intermediary_clone"
    exit 1
fi
if ! grep -qxF "services/api" "$repos_file" 2>/dev/null; then
    echo "FAIL: repos.list should contain 'services/api'"
    cat "$repos_file"
    exit 1
fi
echo "  PASS: repos.list has 'services/api' entry"

echo "Test 8: repos_list_add doesn't duplicate"
repos_list_add "$SOURCE_API" "services/api"
count=$(grep -cxF "services/api" "$repos_file" 2>/dev/null)
if [ "$count" -ne 1 ]; then
    echo "FAIL: repos.list should have exactly 1 entry, has $count"
    exit 1
fi
echo "  PASS: No duplicate entries"

echo "Test 9: repos_list_scopes lists all scopes"
# Add a second scope
repos_list_add "$MONOREPO_PATH" ""  # unscoped / root
# Check the repos file directly (command substitution strips trailing newlines)
repos_file=$(get_repos_list_path "$SOURCE_API")
if ! grep -qxF "services/api" "$repos_file"; then
    echo "FAIL: scopes should include 'services/api'"
    exit 1
fi
# Empty line should represent root
if ! grep -qx '^$' "$repos_file"; then
    echo "FAIL: scopes should include empty line (root)"
    exit 1
fi
echo "  PASS: repos_list_scopes returns all scopes"

echo "Test 10: repos_list_has_parent detects broader scope"
if ! repos_list_has_parent "$SOURCE_API" "services/api"; then
    echo "FAIL: Root scope (empty) should be parent of 'services/api'"
    exit 1
fi
echo "  PASS: Root scope is parent of 'services/api'"

echo "Test 11: repos_list_has_parent returns false for no parent"
repos_list_remove "$SOURCE_API" ""  # Remove root scope
if repos_list_has_parent "$SOURCE_API" "services/api"; then
    echo "FAIL: 'services/api' has no parent after root removal"
    exit 1
fi
echo "  PASS: No parent when root scope removed"

echo "Test 12: repos_list_remove removes entry"
repos_list_remove "$SOURCE_API" "services/api"
if [ -f "$repos_file" ]; then
    if grep -qxF "services/api" "$repos_file" 2>/dev/null; then
        echo "FAIL: 'services/api' should be removed"
        exit 1
    fi
fi
echo "  PASS: repos_list_remove works"

# Re-add for remaining tests
repos_list_add "$SOURCE_API" "services/api"

echo ""
echo "=== Testing scoped post-commit hook ==="
echo ""

# Set up source post-commit hook with scope
setup_source_post_commit "$SOURCE_API" "$cfg_exclude" "$INTERMEDIARY_DIR"

path_hash=$(echo -n "$SOURCE_API" | md5sum | cut -c1-12)
post_commit_hook="$MONOREPO_PATH/.git/hooks/post-commit.d/claude-cage-$path_hash"

echo "Test 13: Scoped hook has SCOPE_PATH"
if ! grep -q '^SCOPE_PATH="services/api"' "$post_commit_hook"; then
    echo "FAIL: Hook should have SCOPE_PATH=\"services/api\""
    grep 'SCOPE_PATH' "$post_commit_hook" || echo "(not found)"
    exit 1
fi
echo "  PASS: Hook has SCOPE_PATH=\"services/api\""

echo "Test 14: Scoped hook reads exclude pathspecs from file"
if ! grep -q 'EXCLUDE_PATHSPECS_FILE=' "$post_commit_hook"; then
    echo "FAIL: Hook should reference EXCLUDE_PATHSPECS_FILE"
    exit 1
fi
if ! grep -q 'PATHSPEC_ARGS' "$post_commit_hook"; then
    echo "FAIL: Hook should build PATHSPEC_ARGS"
    exit 1
fi
echo "  PASS: Hook reads pathspecs from metadata file"

echo "Test 15: Scoped hook syncs in-scope commit with stripped paths"
# Make a commit touching services/api (in-scope)
cd "$MONOREPO_PATH"
echo "api v4" > services/api/app.go
git add -A && git commit -m "In-scope API update" --quiet

api_head=$(git rev-parse HEAD)
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"
if grep -q " ${api_head}$" "$commit_map" 2>/dev/null; then
    echo "  PASS: In-scope commit synced to intermediary"
else
    echo "FAIL: In-scope commit was NOT synced to intermediary"
    echo "  HEAD: $api_head"
    echo "  commit map tail:"
    tail -5 "$commit_map"
    exit 1
fi

# Verify intermediary has stripped paths after hook sync
hook_tree=$(git -C "$INTERMEDIARY_DIR" ls-tree -r --name-only HEAD)
if echo "$hook_tree" | grep -q "^services/"; then
    echo "FAIL: Hook-synced commit should have stripped paths (no services/ prefix)"
    echo "  Tree:"
    echo "$hook_tree"
    exit 1
fi
if ! echo "$hook_tree" | grep -q "^app.go$"; then
    echo "FAIL: Hook-synced commit should have 'app.go' at root"
    echo "  Tree:"
    echo "$hook_tree"
    exit 1
fi
echo "  PASS: Hook-synced commit has stripped paths"

echo "Test 16: Scoped hook maps out-of-scope commit to 0"
echo "web v3" > services/web/index.html
git add -A && git commit -m "Out-of-scope web update" --quiet

web_head=$(git rev-parse HEAD)
if grep -q "^0 ${web_head}$" "$commit_map" 2>/dev/null; then
    echo "  PASS: Out-of-scope commit mapped to 0"
else
    echo "FAIL: Out-of-scope commit should map to 0"
    echo "  HEAD: $web_head"
    echo "  commit map tail:"
    tail -5 "$commit_map"
    exit 1
fi

# Clean up hook
cleanup_source_hooks "$SOURCE_API"

echo ""
echo "=== Testing unscoped intermediary (default behavior) ==="
echo ""

echo "Test 17: Unscoped intermediary has all files"
# Create an unscoped intermediary for the root
UNSCOPED_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "")
rm -rf "$UNSCOPED_IDIR"
CLAUDE_CAGE_SESSION="test-unscoped"
cfg_exclude=".env"
create_intermediary_clone "$MONOREPO_PATH" "" >/dev/null 2>&1

unscoped_tree=$(git -C "$UNSCOPED_IDIR" ls-tree -r --name-only HEAD)
if ! echo "$unscoped_tree" | grep -q "^services/api/"; then
    echo "FAIL: Unscoped should have services/api/"
    exit 1
fi
if ! echo "$unscoped_tree" | grep -q "^services/web/"; then
    echo "FAIL: Unscoped should have services/web/"
    exit 1
fi
if ! echo "$unscoped_tree" | grep -q "^shared/"; then
    echo "FAIL: Unscoped should have shared/"
    exit 1
fi
if ! echo "$unscoped_tree" | grep -q "^README.md$"; then
    echo "FAIL: Unscoped should have README.md"
    exit 1
fi
echo "  PASS: Unscoped intermediary has all files"

echo "Test 18: Unscoped metadata has empty scope path"
unscoped_scope=$(cat "$UNSCOPED_IDIR/claude-cage-scope-path" 2>/dev/null)
if [ -n "$unscoped_scope" ]; then
    echo "FAIL: Unscoped scope-path should be empty, got '$unscoped_scope'"
    exit 1
fi
echo "  PASS: Unscoped scope-path is empty"

echo ""
echo "=== Testing repos_list_clean_orphans ==="
echo ""

echo "Test 19: repos_list_clean_orphans removes entries for missing intermediaries"
# Add a fake scope entry
repos_list_add "$SOURCE_API" "nonexistent/scope"
# Verify it's there
if ! grep -qxF "nonexistent/scope" "$repos_file" 2>/dev/null; then
    echo "FAIL: Setup: orphan entry not added"
    exit 1
fi
repos_list_clean_orphans "$SOURCE_API"
if grep -qxF "nonexistent/scope" "$repos_file" 2>/dev/null; then
    echo "FAIL: Orphan entry should have been removed"
    exit 1
fi
# The real entry should still be there
if ! grep -qxF "services/api" "$repos_file" 2>/dev/null; then
    echo "FAIL: Real entry should be preserved"
    exit 1
fi
echo "  PASS: Orphan entries cleaned, real entries preserved"

echo ""
echo "=== Testing scoped mount logic ==="
echo ""

echo "Test 20: enumerate_projects mounts scoped work at git root"
# Reset session to the scoped one
CLAUDE_CAGE_SESSION="test-scoped"
cfg_isolated="false"

intermediary_root=$(get_intermediary_root)
session_work_root=$(get_session_work_root)

enumerate_projects "$session_work_root" "$intermediary_root" "$(get_work_path "$SOURCE_API")" "$INTERMEDIARY_DIR" "$SOURCE_API"

# The current project should be mounted at git_root (not scope_path)
# so the user sees empty parent dirs above scope with no .git
found_root_mount=false
found_correct_src=false
for entry in "${CAGE_WORK_PROJECTS[@]}"; do
    IFS='|' read -r proj_dir mount_path <<< "$entry"
    if [ "$mount_path" = "$GIT_ROOT" ]; then
        found_root_mount=true
        # Mount source should be session_work_root + git_root (parent of work dir)
        expected_src="$session_work_root$GIT_ROOT"
        if [ "$proj_dir" = "$expected_src" ]; then
            found_correct_src=true
        fi
        break
    fi
done
if [ "$found_root_mount" != true ]; then
    echo "FAIL: Scoped project should mount at git root ($GIT_ROOT)"
    echo "  Work projects:"
    printf '    %s\n' "${CAGE_WORK_PROJECTS[@]}"
    exit 1
fi
echo "  PASS: Scoped work mounts at git root"
if [ "$found_correct_src" != true ]; then
    echo "FAIL: Mount source should be session_work_root + git_root"
    echo "  Expected: $expected_src"
    echo "  Work projects:"
    printf '    %s\n' "${CAGE_WORK_PROJECTS[@]}"
    exit 1
fi
echo "  PASS: Mount source is git-root-level parent directory"

echo ""
echo "=== Testing scoped round-trip sync (intermediary → source) ==="
echo ""

echo "Test 21: Round-trip: stripped-path commit syncs back to source with --directory"
# Reset to the scoped session and its intermediary
CLAUDE_CAGE_SESSION="test-scoped"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")

# Create a commit directly in the intermediary with stripped paths
# First, clone intermediary to a temp work dir
ROUND_TRIP_WORK=$(mktemp -d "$TEST_TMP/round-trip-work.XXXXXX")
git clone "$INTERMEDIARY_DIR" "$ROUND_TRIP_WORK" --quiet 2>/dev/null
cd "$ROUND_TRIP_WORK"
git config user.email "test@test.com"
git config user.name "Test"
echo "round-trip content" > app.go
git add -A && git commit -m "Round-trip test commit" --quiet

# Get the commit hash
rt_commit=$(git rev-parse HEAD)
rt_parent=$(git rev-parse HEAD^)

# Push to intermediary (disable hooks to avoid pipe blocking)
rm -f "$INTERMEDIARY_DIR/hooks/post-receive"
git push origin "$BRANCH_NAME" --quiet 2>/dev/null

# Now sync this commit to source using sync_to_source
cd "$MONOREPO_PATH"
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"

# Record the source HEAD before sync
source_head_before=$(git rev-parse HEAD)

# Call sync_to_source
sync_to_source "$MONOREPO_PATH" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$rt_parent" >/dev/null 2>&1

# Verify source HEAD moved
source_head_after=$(git rev-parse HEAD)
if [ "$source_head_after" = "$source_head_before" ]; then
    echo "FAIL: Source HEAD didn't change after sync"
    echo "  commit map tail:"
    tail -5 "$commit_map"
    exit 1
fi

# Verify the file is at the correct full path (services/api/app.go)
source_content=$(cat "$MONOREPO_PATH/services/api/app.go")
if [ "$source_content" != "round-trip content" ]; then
    echo "FAIL: Source services/api/app.go should have 'round-trip content', got '$source_content'"
    exit 1
fi
echo "  PASS: Round-trip commit applied at correct path (services/api/app.go)"

# Verify commit was mapped
if ! grep -q "^${rt_commit} " "$commit_map" 2>/dev/null; then
    echo "FAIL: Round-trip commit not in mapping"
    exit 1
fi
echo "  PASS: Round-trip commit mapped correctly"

# Verify other files weren't affected
web_content=$(cat "$MONOREPO_PATH/services/web/index.html")
if [ "$web_content" != "web v3" ]; then
    echo "FAIL: services/web/index.html was modified (should be untouched)"
    exit 1
fi
echo "  PASS: Out-of-scope files untouched"

echo ""
echo "=== Testing source commit after cage round-trip ==="
echo ""

echo "Test 22: Source commit after round-trip syncs to scoped intermediary"
# After Test 21, sync_to_source applied a cage commit to source via git am.
# Now verify that a new source commit correctly syncs to the intermediary.
# This tests the marks gap fix: sync_to_source records marks for git-am'd commits
# so post-commit hook fast-exports can reference them as parents.
CLAUDE_CAGE_SESSION="test-roundtrip"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
cd "$MONOREPO_PATH"

# Install post-commit hook (re-install with current intermediary paths)
cfg_exclude=".env"
setup_source_post_commit "$SOURCE_API" "$cfg_exclude" "$INTERMEDIARY_DIR"

# Get intermediary HEAD before the source commit
int_head_before=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)

# Make a new in-scope commit on source
echo "post-roundtrip update" > services/api/app.go
git add services/api/app.go
hook_output=$(git commit -m "Source commit after round-trip" 2>&1)

# The hook should NOT say "excluded files"
if echo "$hook_output" | grep -q "only has excluded files"; then
    echo "FAIL: Post-commit hook falsely reported excluded-only"
    echo "  Hook output: $hook_output"
    echo "  Sync log:"
    cat "$INTERMEDIARY_DIR/sync.log" 2>/dev/null
    exit 1
fi

# Verify the intermediary HEAD advanced
int_head_after=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)
if [ "$int_head_after" = "$int_head_before" ]; then
    echo "FAIL: Intermediary HEAD didn't advance after source commit"
    echo "  Hook output: $hook_output"
    echo "  Sync log:"
    cat "$INTERMEDIARY_DIR/sync.log" 2>/dev/null
    exit 1
fi
echo "  PASS: Source commit after round-trip synced to intermediary"

# Verify the synced commit has correct content (stripped paths)
int_content=$(git -C "$INTERMEDIARY_DIR" show "$BRANCH_NAME:app.go" 2>/dev/null)
if [ "$int_content" != "post-roundtrip update" ]; then
    echo "FAIL: Intermediary app.go should be 'post-roundtrip update', got '$int_content'"
    exit 1
fi
echo "  PASS: Synced commit has correct content with stripped paths"

# Verify commit mapping was updated
source_head=$(git -C "$MONOREPO_PATH" rev-parse HEAD)
if ! grep -q " ${source_head}$" "$INTERMEDIARY_DIR/claude-cage-commit-map" 2>/dev/null; then
    echo "FAIL: Source HEAD not in commit mapping after hook sync"
    exit 1
fi
echo "  PASS: Commit mapping updated correctly"

# Clean up hook so subsequent test commits don't trigger stale hook
path_hash=$(echo -n "$SOURCE_API" | md5sum | cut -c1-12)
rm -f "$MONOREPO_PATH/.git/hooks/post-commit.d/claude-cage-$path_hash"

echo ""
echo "=== Testing binary blob safety in scoped stripping ==="
echo ""

echo "Test 23: Binary blob with scope-prefix-like content survives stripping"
# Create a fresh scoped intermediary with a binary file that contains bytes
# mimicking fast-export M/D lines with the scope prefix. The sed filter must
# not corrupt blob data — only actual M/D/R/C path lines should be modified.
cd "$MONOREPO_PATH"

# Create binary content that looks like a fast-export M line with the scope prefix
# This would be corrupted if the sed filter ran inside blob data sections
printf 'M 100644 inline services/api/sneaky\nD services/api/trick\nreal binary\x00\x01\x02' \
    > services/api/binary.dat
echo "text file v5" > services/api/app.go
git add -A && git commit -m "Binary and text in scope" --quiet

# Rebuild the scoped intermediary from scratch to include the binary commit
rm -rf "$INTERMEDIARY_DIR"
CLAUDE_CAGE_SESSION="test-binary"
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

# Clone intermediary to inspect content
BINARY_CHECK=$(mktemp -d "$TEST_TMP/binary-check.XXXXXX")
git clone "$INTERMEDIARY_DIR" "$BINARY_CHECK" --quiet 2>/dev/null

# Verify text file has stripped path and correct content
if [ ! -f "$BINARY_CHECK/app.go" ]; then
    echo "FAIL: app.go should exist with stripped path"
    ls -la "$BINARY_CHECK/"
    exit 1
fi
check_content=$(cat "$BINARY_CHECK/app.go")
if [ "$check_content" != "text file v5" ]; then
    echo "FAIL: app.go content wrong: '$check_content'"
    exit 1
fi
echo "  PASS: Text file has correct stripped path and content"

# Verify binary file exists with stripped path
if [ ! -f "$BINARY_CHECK/binary.dat" ]; then
    echo "FAIL: binary.dat should exist with stripped path"
    ls -la "$BINARY_CHECK/"
    exit 1
fi

# Verify binary content is intact (compare byte-for-byte with source)
if ! cmp -s "$MONOREPO_PATH/services/api/binary.dat" "$BINARY_CHECK/binary.dat"; then
    echo "FAIL: binary.dat content differs from source (corruption!)"
    echo "  Source (hex):"
    xxd "$MONOREPO_PATH/services/api/binary.dat" | head -5
    echo "  Intermediary (hex):"
    xxd "$BINARY_CHECK/binary.dat" | head -5
    exit 1
fi
echo "  PASS: Binary blob content is byte-for-byte identical (no corruption)"

echo ""
echo "=== Testing C-quoted path stripping ==="
echo ""

echo "Test 24: C-quoted paths (non-ASCII filenames) have scope prefix stripped"
# Git C-quotes paths containing high-bit bytes (>= 0x80), backslashes, tabs, or
# double quotes. The strip-prefix awk must handle both unquoted and quoted forms.
cd "$MONOREPO_PATH"

# Create a file with a non-ASCII character (é = 0xc3 0xa9 in UTF-8)
# This triggers C-quoting in fast-export: "services/api/caf\303\251.txt"
printf 'special content' > "services/api/caf$(printf '\xc3\xa9').txt"
git add -A && git commit -m "File with non-ASCII name" --quiet

# Rebuild the scoped intermediary from scratch
rm -rf "$INTERMEDIARY_DIR"
CLAUDE_CAGE_SESSION="test-quoted"
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

# Check intermediary tree for unstripped paths
quoted_tree=$(git -C "$INTERMEDIARY_DIR" ls-tree -r --name-only HEAD)
if echo "$quoted_tree" | grep -q "^services/"; then
    echo "FAIL: C-quoted path still has services/ prefix"
    echo "  Tree listing:"
    echo "$quoted_tree"
    exit 1
fi
echo "  PASS: No services/ prefix in C-quoted paths"

# Verify the file exists with stripped path by cloning and checking
QUOTED_CHECK=$(mktemp -d "$TEST_TMP/quoted-check.XXXXXX")
git clone "$INTERMEDIARY_DIR" "$QUOTED_CHECK" --quiet 2>/dev/null
expected_file="$QUOTED_CHECK/caf$(printf '\xc3\xa9').txt"
if [ ! -f "$expected_file" ]; then
    echo "FAIL: C-quoted file should exist with stripped path"
    ls -la "$QUOTED_CHECK/"
    exit 1
fi
quoted_content=$(cat "$expected_file")
if [ "$quoted_content" != "special content" ]; then
    echo "FAIL: C-quoted file content wrong: '$quoted_content'"
    exit 1
fi
echo "  PASS: C-quoted file has correct stripped path and content"

echo ""
echo "=== Testing cross-scope session discovery ==="
echo ""

echo "Test 25: list_cached_sessions from git root shows scoped session"
# The scoped session (test-scoped) created earlier should be visible from git root
CLAUDE_CAGE_SESSION="test-scoped"
# Ensure repos.list has the services/api entry
repos_list_add "$SOURCE_API" "services/api"

sessions=$(list_cached_sessions "$MONOREPO_PATH")
if [ -z "$sessions" ]; then
    echo "FAIL: list_cached_sessions from git root returned nothing"
    exit 1
fi
# Should find the scoped session with source_dir=$SOURCE_API and scope=services/api
if ! echo "$sessions" | grep -q "$SOURCE_API"; then
    echo "FAIL: Scoped session should be visible from git root"
    echo "  Sessions:"
    echo "$sessions"
    exit 1
fi
if ! echo "$sessions" | grep -q "services/api"; then
    echo "FAIL: Session listing should include scope 'services/api'"
    echo "  Sessions:"
    echo "$sessions"
    exit 1
fi
echo "  PASS: Scoped session visible from git root"

echo "Test 26: list_cached_sessions from scoped dir shows unscoped session"
# The unscoped session (test-unscoped) created earlier should be visible from services/api
repos_list_add "$SOURCE_API" ""  # Ensure root/unscoped is registered
sessions_from_api=$(list_cached_sessions "$SOURCE_API")
if ! echo "$sessions_from_api" | grep -q "test-unscoped"; then
    echo "FAIL: Unscoped session should be visible from services/api"
    echo "  Sessions:"
    echo "$sessions_from_api"
    exit 1
fi
echo "  PASS: Unscoped session visible from scoped dir"

echo "Test 27: list_cached_sessions output includes source_dir and scope fields"
# Check format: session_id branch source_dir scope
line=$(echo "$sessions_from_api" | head -1)
field_count=$(echo "$line" | wc -w)
if [ "$field_count" -lt 3 ]; then
    echo "FAIL: Session line should have at least 3 fields (sid branch source_dir), got $field_count"
    echo "  Line: '$line'"
    exit 1
fi
echo "  PASS: Session output has expected field count"

echo "Test 28: find_reusable_session discovers cross-scope dirty sessions"
# Make the scoped session dirty
SCOPED_WORK="$CLAUDE_CAGE_CACHE/sessions/test-scoped/work$SOURCE_API"
if [ -d "$SCOPED_WORK" ]; then
    echo "dirty" >> "$SCOPED_WORK/app.go"
fi
# Run find_reusable_session from the git root
find_reusable_session "$MONOREPO_PATH"
if [ -z "$REUSE_DIRTY_SESSIONS" ]; then
    echo "FAIL: Should find dirty cross-scope session from git root"
    echo "  state: $REUSE_SESSION_STATE"
    exit 1
fi
if ! echo "$REUSE_DIRTY_SESSIONS" | grep -q "$SOURCE_API"; then
    echo "FAIL: Dirty session listing should contain scoped source_dir"
    echo "  Dirty sessions:"
    echo "$REUSE_DIRTY_SESSIONS"
    exit 1
fi
echo "  PASS: Cross-scope dirty session discovered from git root"
# Clean up repos.list root entry
repos_list_remove "$SOURCE_API" ""

echo ""
echo "=== Testing sparse checkout reuse ==="
echo ""

# Clean up work dirs for a fresh start
rm -rf "$CLAUDE_CAGE_CACHE/sessions"

# Make sure the root unscoped intermediary exists (from Test 17)
UNSCOPED_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "")
if [ ! -d "$UNSCOPED_IDIR" ]; then
    CLAUDE_CAGE_SESSION="test-sparse-setup"
    cfg_exclude=".env"
    create_intermediary_clone "$MONOREPO_PATH" "" >/dev/null 2>&1
fi
# Ensure repos.list has root entry
repos_list_add "$MONOREPO_PATH" ""

# Make sure the scoped intermediary exists (from Test 4)
SCOPED_IDIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
if [ ! -d "$SCOPED_IDIR" ]; then
    CLAUDE_CAGE_SESSION="test-sparse-setup2"
    cfg_exclude=".env"
    create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1
fi
repos_list_add "$SOURCE_API" "services/api"

echo "Test 29: find_broader_intermediary detects root intermediary for scoped request"
if ! find_broader_intermediary "$SOURCE_API" "services/api"; then
    echo "FAIL: find_broader_intermediary should find root intermediary"
    exit 1
fi
if [ "$BROADER_INTERMEDIARY_DIR" != "$UNSCOPED_IDIR" ]; then
    echo "FAIL: BROADER_INTERMEDIARY_DIR should be '$UNSCOPED_IDIR', got '$BROADER_INTERMEDIARY_DIR'"
    exit 1
fi
if [ -n "$BROADER_SCOPE_PATH" ]; then
    echo "FAIL: BROADER_SCOPE_PATH should be empty (root), got '$BROADER_SCOPE_PATH'"
    exit 1
fi
if [ "$BROADER_SOURCE_DIR" != "$MONOREPO_PATH" ]; then
    echo "FAIL: BROADER_SOURCE_DIR should be '$MONOREPO_PATH', got '$BROADER_SOURCE_DIR'"
    exit 1
fi
echo "  PASS: Root intermediary found as broader scope"

echo "Test 30: find_broader_intermediary prefers narrowest parent"
# Add a mid-level scope "services" to repos.list and create its intermediary
SERVICES_SOURCE="$MONOREPO_PATH/services"
mkdir -p "$SERVICES_SOURCE"
CLAUDE_CAGE_SESSION="test-sparse-narrow"
repos_list_add "$SOURCE_API" "services"
SERVICES_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "services")
# Create a minimal scoped intermediary for services/
cfg_exclude=".env"
# Temporarily create scoped intermediary — we need a real one for hash matching
create_intermediary_clone "$SERVICES_SOURCE" "services" >/dev/null 2>&1

if ! find_broader_intermediary "$SOURCE_API" "services/api"; then
    echo "FAIL: find_broader_intermediary should find services/ as parent"
    exit 1
fi
if [ "$BROADER_SCOPE_PATH" != "services" ]; then
    echo "FAIL: BROADER_SCOPE_PATH should be 'services' (narrowest parent), got '$BROADER_SCOPE_PATH'"
    exit 1
fi
echo "  PASS: Narrowest parent 'services' preferred over root"
# Clean up services intermediary (not needed after this test)
rm -rf "$SERVICES_IDIR"
repos_list_remove "$SOURCE_API" "services"

echo "Test 31: find_broader_intermediary returns 1 when exclude hash mismatches"
# Change cfg_exclude to cause hash mismatch
old_exclude="$cfg_exclude"
cfg_exclude=".env|*.log|different_pattern"
if find_broader_intermediary "$SOURCE_API" "services/api"; then
    echo "FAIL: find_broader_intermediary should fail with mismatched exclude hash"
    exit 1
fi
cfg_exclude="$old_exclude"
echo "  PASS: Returns 1 on exclude hash mismatch"

echo "Test 32: find_broader_intermediary returns 1 when no broader intermediary exists"
# Remove root entry
repos_list_remove "$SOURCE_API" ""
if find_broader_intermediary "$SOURCE_API" "services/api"; then
    echo "FAIL: find_broader_intermediary should fail with no broader scope"
    exit 1
fi
echo "  PASS: Returns 1 when no broader intermediary"
# Restore root entry
repos_list_add "$SOURCE_API" ""

echo ""
echo "Test 33: create_sparse_work_dir creates sparse checkout of broader intermediary"
CLAUDE_CAGE_SESSION="test-sparse-work"
export CLAUDE_CAGE_SESSION
cfg_exclude=".env"

# Get current branch
BRANCH_NAME=$(git -C "$MONOREPO_PATH" branch --show-current)

create_sparse_work_dir "$UNSCOPED_IDIR" "$MONOREPO_PATH" "services/api" "" >/dev/null 2>&1

SPARSE_WORK=$(get_work_path "$MONOREPO_PATH")
if [ ! -d "$SPARSE_WORK/.git" ]; then
    echo "FAIL: Sparse work dir should exist with .git"
    exit 1
fi
echo "  PASS: Sparse work dir created"

echo "Test 34: create_sparse_work_dir computes relative scope correctly"
# The sparse checkout cone should be services/api (relative to root)
sparse_cone=$(git -C "$SPARSE_WORK" sparse-checkout list 2>/dev/null)
if [ "$sparse_cone" != "services/api" ]; then
    echo "FAIL: Sparse cone should be 'services/api', got '$sparse_cone'"
    exit 1
fi
echo "  PASS: Sparse cone is 'services/api'"

echo "Test 35: create_sparse_work_dir writes metadata"
if [ ! -f "$SPARSE_WORK/.git/claude-cage-sparse-reuse" ]; then
    echo "FAIL: claude-cage-sparse-reuse flag not written"
    exit 1
fi
sparse_flag=$(cat "$SPARSE_WORK/.git/claude-cage-sparse-reuse")
if [ "$sparse_flag" != "1" ]; then
    echo "FAIL: sparse-reuse flag should be '1', got '$sparse_flag'"
    exit 1
fi
broader_meta=$(cat "$SPARSE_WORK/.git/claude-cage-broader-intermediary" 2>/dev/null)
if [ "$broader_meta" != "$UNSCOPED_IDIR" ]; then
    echo "FAIL: broader-intermediary metadata should be '$UNSCOPED_IDIR', got '$broader_meta'"
    exit 1
fi
scope_meta=$(cat "$SPARSE_WORK/.git/claude-cage-scope-path" 2>/dev/null)
if [ "$scope_meta" != "services/api" ]; then
    echo "FAIL: scope-path metadata should be 'services/api', got '$scope_meta'"
    exit 1
fi
echo "  PASS: All metadata written correctly"

echo "Test 36: Sparse reuse work dir: in-scope files visible, out-of-scope NOT"
if [ ! -f "$SPARSE_WORK/services/api/app.go" ]; then
    echo "FAIL: services/api/app.go should be visible in sparse checkout"
    ls -la "$SPARSE_WORK/services/" 2>/dev/null || echo "(services/ not found)"
    exit 1
fi
if [ -f "$SPARSE_WORK/services/web/index.html" ]; then
    echo "FAIL: services/web/index.html should NOT be visible (outside sparse cone)"
    exit 1
fi
if [ -f "$SPARSE_WORK/shared/lib.go" ]; then
    echo "FAIL: shared/lib.go should NOT be visible (outside sparse cone)"
    exit 1
fi
echo "  PASS: Only in-scope files visible"

echo "Test 37: create_sparse_work_dir with non-root broader scope computes relative path"
# Create a services-scoped intermediary, then request services/api from it
CLAUDE_CAGE_SESSION="test-sparse-relative"
repos_list_add "$SOURCE_API" "services"
SERVICES_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "services")
cfg_exclude=".env"
create_intermediary_clone "$SERVICES_SOURCE" "services" >/dev/null 2>&1

create_sparse_work_dir "$SERVICES_IDIR" "$SERVICES_SOURCE" "services/api" "services" >/dev/null 2>&1

RELATIVE_WORK=$(get_work_path "$SERVICES_SOURCE")
if [ ! -d "$RELATIVE_WORK/.git" ]; then
    echo "FAIL: Relative sparse work dir should exist"
    exit 1
fi
relative_cone=$(git -C "$RELATIVE_WORK" sparse-checkout list 2>/dev/null)
if [ "$relative_cone" != "api" ]; then
    echo "FAIL: Relative sparse cone should be 'api' (services stripped), got '$relative_cone'"
    exit 1
fi
echo "  PASS: Relative scope 'api' computed correctly (broader=services, request=services/api)"

# Clean up services intermediary
rm -rf "$SERVICES_IDIR"
repos_list_remove "$SOURCE_API" "services"

echo ""
echo "Test 38: clean_session_cache with sparse-reuse skips intermediary deletion"
# Clean the sparse-reuse session and verify intermediary survives
CLAUDE_CAGE_SESSION="test-sparse-work"
SPARSE_WORK=$(get_work_path "$MONOREPO_PATH")
# Verify work dir exists before clean
if [ ! -d "$SPARSE_WORK/.git" ]; then
    echo "FAIL: Setup: sparse work dir should exist"
    exit 1
fi
clean_session_cache "$MONOREPO_PATH" "test-sparse-work" >/dev/null 2>&1

# Work dir should be gone
if [ -d "$SPARSE_WORK" ]; then
    echo "FAIL: Work dir should be removed after clean"
    exit 1
fi
# Broader intermediary should still exist
if [ ! -d "$UNSCOPED_IDIR" ]; then
    echo "FAIL: Broader intermediary should NOT be deleted by sparse-reuse cleanup"
    exit 1
fi
echo "  PASS: Sparse-reuse cleanup skips broader intermediary"

echo ""
echo "=== Testing scope promotion ==="
echo ""

# Set up: create a scoped intermediary for services/web with synced commits
cd "$MONOREPO_PATH"
CLAUDE_CAGE_SESSION="test-promote-setup"
cfg_exclude=".env"
WEB_SOURCE="$MONOREPO_PATH/services/web"
repos_list_add "$WEB_SOURCE" "services/web"
WEB_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "services/web")
create_intermediary_clone "$WEB_SOURCE" "services/web" >/dev/null 2>&1

echo "Test 39: repos_list_children finds narrower scopes"
# Ensure both scoped entries exist
repos_list_add "$SOURCE_API" "services/api"
children=$(repos_list_children "$MONOREPO_PATH" "")
if ! echo "$children" | grep -q "services/api"; then
    echo "FAIL: Root should see services/api as child"
    echo "  Children: $children"
    exit 1
fi
if ! echo "$children" | grep -q "services/web"; then
    echo "FAIL: Root should see services/web as child"
    echo "  Children: $children"
    exit 1
fi
echo "  PASS: Root scope finds narrower children"

echo "Test 40: repos_list_children returns nothing for leaf scope"
leaf_children=$(repos_list_children "$MONOREPO_PATH" "services/api")
if [ -n "$leaf_children" ]; then
    echo "FAIL: Leaf scope 'services/api' should have no children, got: $leaf_children"
    exit 1
fi
echo "  PASS: Leaf scope has no children"

echo "Test 41: can_promote_scope returns 0 for synced child with no sessions"
# services/web intermediary exists with synced commits, no active sessions
if ! can_promote_scope "$MONOREPO_PATH" "services/web"; then
    echo "FAIL: services/web should be promotable (synced, no sessions)"
    exit 1
fi
echo "  PASS: Synced child with no sessions is promotable"

echo "Test 42: can_promote_scope returns 1 when child has dirty work dir"
# Create a dirty work dir for services/api
CLAUDE_CAGE_SESSION="test-promote-dirty"
SCOPED_IDIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
if [ ! -d "$SCOPED_IDIR" ]; then
    create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1
fi
DIRTY_WORK=$(get_work_path "$SOURCE_API")
if [ ! -d "$DIRTY_WORK" ]; then
    git clone "$SCOPED_IDIR" "$DIRTY_WORK" --quiet 2>/dev/null
fi
echo "dirty" >> "$DIRTY_WORK/app.go"

if can_promote_scope "$MONOREPO_PATH" "services/api"; then
    echo "FAIL: services/api should NOT be promotable (dirty work dir)"
    exit 1
fi
echo "  PASS: Dirty child work dir blocks promotion"

# Clean up dirty work dir
rm -rf "$DIRTY_WORK"
# Clean empty parent dirs
_pdir=$(dirname "$DIRTY_WORK")
while [ "$_pdir" != "$CLAUDE_CAGE_CACHE/sessions/test-promote-dirty/work" ] && \
      [ "$_pdir" != "$CLAUDE_CAGE_CACHE/sessions/test-promote-dirty" ]; do
    [ -d "$_pdir" ] && [ -z "$(ls -A "$_pdir" 2>/dev/null)" ] && rm -rf "$_pdir" || break
    _pdir=$(dirname "$_pdir")
done

echo "Test 43: promote_scope removes intermediary, work dirs, and repos_list entry"
# Promote services/web (which is clean and synced)
WEB_WORK="$CLAUDE_CAGE_CACHE/sessions/test-promote-setup/work$WEB_SOURCE"
if [ ! -d "$WEB_IDIR" ]; then
    echo "FAIL: Setup: services/web intermediary should exist before promotion"
    exit 1
fi
promote_scope "$MONOREPO_PATH" "services/web" >/dev/null 2>&1

if [ -d "$WEB_IDIR" ]; then
    echo "FAIL: services/web intermediary should be removed after promotion"
    exit 1
fi
repos_file=$(get_repos_list_path "$MONOREPO_PATH")
if [ -f "$repos_file" ] && grep -qxF "services/web" "$repos_file" 2>/dev/null; then
    echo "FAIL: services/web should be removed from repos.list"
    exit 1
fi
if [ -d "$WEB_WORK" ]; then
    echo "FAIL: services/web work dir should be removed after promotion"
    exit 1
fi
echo "  PASS: Promotion removes intermediary, work dirs, and repos.list entry"

echo ""
echo "=== Testing Bug 1: In-scope branches with no unique in-scope commits ==="
echo ""

# Reset to a clean state for bug tests
cd "$MONOREPO_PATH"
# Clean up any leftover hooks
rm -rf "$MONOREPO_PATH/.git/hooks/post-commit.d"
rm -f "$MONOREPO_PATH/.git/hooks/post-commit"

echo "Test 44: Branch with no unique in-scope commits gets ref in scoped intermediary"
# Create a branch from master that only touches out-of-scope files
git checkout -b testbranch2
echo "web-only on branch" > services/web/index.html
git add -A && git commit -m "Web-only change on testbranch2" --quiet
git checkout "$BRANCH_NAME"

# Rebuild scoped intermediary for services/api
rm -rf "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"
rm -rf "$CLAUDE_CAGE_CACHE/sessions"
CLAUDE_CAGE_SESSION="test-bug1"
cfg_exclude=".env"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
repos_file=$(get_repos_list_path "$SOURCE_API")
rm -f "$repos_file"
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

# testbranch2 should have a ref in intermediary even with no in-scope changes
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify testbranch2 >/dev/null 2>&1; then
    echo "FAIL: testbranch2 should exist in intermediary (no unique in-scope commits)"
    echo "  Intermediary branches:"
    git -C "$INTERMEDIARY_DIR" branch --list 2>/dev/null
    exit 1
fi
echo "  PASS: Branch with no in-scope changes has ref in intermediary"

echo "Test 45: catchup_intermediary_branches adds branch with no unique in-scope commits"
# Create another branch after intermediary exists
git checkout -b testbranch5
echo "web-only on branch5" > services/web/index.html
git add -A && git commit -m "Web-only on testbranch5" --quiet
git checkout "$BRANCH_NAME"

# catchup should add testbranch5 to intermediary
catchup_intermediary_branches "$SOURCE_API" "$INTERMEDIARY_DIR" >/dev/null 2>&1 || true
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify testbranch5 >/dev/null 2>&1; then
    echo "FAIL: testbranch5 should be added by catchup even with no in-scope commits"
    echo "  Intermediary branches:"
    git -C "$INTERMEDIARY_DIR" branch --list 2>/dev/null
    exit 1
fi
echo "  PASS: catchup adds branch with no unique in-scope commits"

# Clean up test branches
git checkout "$BRANCH_NAME"

echo ""
echo "=== Testing Bug 2: Temp-index .git path for scoped sync ==="
echo ""

echo "Test 46: sync_to_source temp-index works for scoped intermediary"
# Create a scoped intermediary for services/api
rm -rf "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"
rm -rf "$CLAUDE_CAGE_CACHE/sessions"
CLAUDE_CAGE_SESSION="test-bug2"
cfg_exclude=".env"
repos_file=$(get_repos_list_path "$SOURCE_API")
rm -f "$repos_file"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

# Source needs to be on a DIFFERENT branch than the push target
# Cage is on $BRANCH_NAME, switch source to testbranch2
git checkout testbranch2

# Create a commit in intermediary (simulating cage push)
BUG2_WORK=$(mktemp -d "$TEST_TMP/bug2-work.XXXXXX")
git clone "$INTERMEDIARY_DIR" "$BUG2_WORK" --quiet 2>/dev/null
cd "$BUG2_WORK"
git config user.email "test@test.com"
git config user.name "Test"
echo "temp-index test" > app.go
git add -A && git commit -m "Temp-index test commit" --quiet
bug2_commit=$(git rev-parse HEAD)
bug2_parent=$(git rev-parse HEAD^)

# Push to intermediary (disable hooks to avoid pipe blocking)
rm -f "$INTERMEDIARY_DIR/hooks/post-receive"
git push origin "$BRANCH_NAME" --quiet 2>/dev/null

# Now sync: source is on testbranch2, push was to $BRANCH_NAME -> temp-index path
cd "$MONOREPO_PATH"
# Call sync_to_source with the SCOPED source_dir (not git root)
# This is the bug: source_dir is a subdir, and sync_to_source tries $source_dir/.git/
sync_output=$(sync_to_source "$SOURCE_API" "$INTERMEDIARY_DIR" "refs/heads/$BRANCH_NAME" "$bug2_parent" 2>&1)
sync_rc=$?

# Should NOT fail with "No such file or directory" for .git path
if echo "$sync_output" | grep -qi "no such file or directory"; then
    echo "FAIL: sync_to_source failed with .git path error for scoped source_dir"
    echo "  Output: $sync_output"
    exit 1
fi
if echo "$sync_output" | grep -qi "unable to create.*tmp-index"; then
    echo "FAIL: sync_to_source can't create tmp-index in scoped subdir"
    echo "  Output: $sync_output"
    exit 1
fi

# Verify the commit was applied to $BRANCH_NAME
new_head=$(git -C "$MONOREPO_PATH" rev-parse "$BRANCH_NAME" 2>/dev/null)
source_content=$(git -C "$MONOREPO_PATH" show "${BRANCH_NAME}:services/api/app.go" 2>/dev/null)
if [ "$source_content" != "temp-index test" ]; then
    echo "FAIL: Temp-index commit not applied to source $BRANCH_NAME"
    echo "  Content: '$source_content'"
    echo "  sync_output: $sync_output"
    exit 1
fi
echo "  PASS: sync_to_source temp-index works for scoped intermediary"

# Restore source to main branch
git checkout "$BRANCH_NAME"

echo ""
echo "=== Testing Bug 3: Post-commit hook creates branch not in intermediary ==="
echo ""

echo "Test 47: Post-commit hook creates branch and syncs when branch not in intermediary"
# Clean slate
rm -rf "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"
rm -rf "$CLAUDE_CAGE_CACHE/sessions"
rm -rf "$MONOREPO_PATH/.git/hooks/post-commit.d"
rm -f "$MONOREPO_PATH/.git/hooks/post-commit"
cd "$MONOREPO_PATH"
CLAUDE_CAGE_SESSION="test-bug3"
cfg_exclude=".env"
repos_file=$(get_repos_list_path "$SOURCE_API")
rm -f "$repos_file"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

# Install source post-commit hook
setup_source_post_commit "$SOURCE_API" "$cfg_exclude" "$INTERMEDIARY_DIR"

# Create a new branch NOT in the intermediary and make an in-scope commit
git checkout -b testbranch4
echo "api on branch4" > services/api/app.go
git add services/api/app.go
hook_output=$(git commit -m "API change on testbranch4" 2>&1)

# Should NOT say "skipped: branch testbranch4 not in intermediary"
commit_map="$INTERMEDIARY_DIR/claude-cage-commit-map"
api_head=$(git rev-parse HEAD)
if ! grep -q " ${api_head}$" "$commit_map" 2>/dev/null; then
    echo "FAIL: In-scope commit on new branch should sync to intermediary"
    echo "  Hook output: $hook_output"
    echo "  Sync log:"
    cat "$INTERMEDIARY_DIR/sync.log" 2>/dev/null | tail -10
    exit 1
fi

# testbranch4 should now exist in intermediary
if ! git -C "$INTERMEDIARY_DIR" rev-parse --verify testbranch4 >/dev/null 2>&1; then
    echo "FAIL: testbranch4 should now exist in intermediary"
    exit 1
fi
echo "  PASS: Hook creates branch and syncs in-scope commit"

# Clean up hooks
path_hash=$(echo -n "$SOURCE_API" | md5sum | cut -c1-12)
rm -f "$MONOREPO_PATH/.git/hooks/post-commit.d/claude-cage-$path_hash"

echo ""
echo "=== Testing Bug 4: Cross-scope commit propagation ==="
echo ""

echo "Test 48: Cross-scope commit propagates to narrower-scope intermediary"
# Create both services/api and services/web scoped intermediaries
cd "$MONOREPO_PATH"
git checkout "$BRANCH_NAME"
rm -rf "$MONOREPO_PATH/.git/hooks/post-commit.d"
rm -f "$MONOREPO_PATH/.git/hooks/post-commit"

# Recreate both intermediaries
rm -rf "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"
rm -rf "$CLAUDE_CAGE_CACHE/sessions"
repos_file=$(get_repos_list_path "$SOURCE_API")
rm -f "$repos_file"

CLAUDE_CAGE_SESSION="test-bug4-api"
cfg_exclude=".env"
INTERMEDIARY_DIR=$(get_scoped_intermediary_path "$SOURCE_API" "services/api")
create_intermediary_clone "$SOURCE_API" "services/api" >/dev/null 2>&1

CLAUDE_CAGE_SESSION="test-bug4-web"
WEB_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "services/web")
WEB_SOURCE="$MONOREPO_PATH/services/web"
create_intermediary_clone "$WEB_SOURCE" "services/web" >/dev/null 2>&1

# Install hooks for both
setup_source_post_commit "$SOURCE_API" "$cfg_exclude" "$INTERMEDIARY_DIR"
setup_source_post_commit "$WEB_SOURCE" "$cfg_exclude" "$WEB_IDIR"

# Record intermediary HEADs before commit
api_int_head_before=$(git -C "$INTERMEDIARY_DIR" rev-parse "$BRANCH_NAME" 2>/dev/null)
web_int_head_before=$(git -C "$WEB_IDIR" rev-parse "$BRANCH_NAME" 2>/dev/null)

# Source commit that touches BOTH scopes
echo "cross-scope api" > services/api/app.go
echo "cross-scope web" > services/web/index.html
git add -A && git commit -m "Cross-scope commit" --quiet

source_head=$(git rev-parse HEAD)
api_commit_map=$(get_commit_map_path "$INTERMEDIARY_DIR")
web_commit_map=$(get_commit_map_path "$WEB_IDIR")

# Both intermediaries should receive the update
if ! grep -q " ${source_head}$" "$api_commit_map" 2>/dev/null; then
    echo "FAIL: Cross-scope commit not synced to API intermediary"
    echo "  API sync log:"
    cat "$INTERMEDIARY_DIR/sync.log" 2>/dev/null | tail -5
    exit 1
fi
if ! grep -q " ${source_head}$" "$web_commit_map" 2>/dev/null; then
    echo "FAIL: Cross-scope commit not synced to Web intermediary"
    echo "  Web sync log:"
    cat "$WEB_IDIR/sync.log" 2>/dev/null | tail -5
    exit 1
fi
echo "  PASS: Cross-scope commit propagated to both intermediaries"

# Verify content in both intermediaries
api_content=$(git -C "$INTERMEDIARY_DIR" show "${BRANCH_NAME}:app.go" 2>/dev/null)
web_content=$(git -C "$WEB_IDIR" show "${BRANCH_NAME}:index.html" 2>/dev/null)
if [ "$api_content" != "cross-scope api" ]; then
    echo "FAIL: API intermediary should have 'cross-scope api', got '$api_content'"
    exit 1
fi
if [ "$web_content" != "cross-scope web" ]; then
    echo "FAIL: Web intermediary should have 'cross-scope web', got '$web_content'"
    exit 1
fi
echo "  PASS: Both intermediaries have correct content"

# Clean up hooks
api_hash=$(echo -n "$SOURCE_API" | md5sum | cut -c1-12)
web_hash=$(echo -n "$WEB_SOURCE" | md5sum | cut -c1-12)
rm -f "$MONOREPO_PATH/.git/hooks/post-commit.d/claude-cage-$api_hash"
rm -f "$MONOREPO_PATH/.git/hooks/post-commit.d/claude-cage-$web_hash"

echo ""
echo "=== Testing Bug 5: Sparse reuse round-trip sync ==="
echo ""

echo "Test 49: Sparse reuse work dir round-trip sync via sync_to_source"
# Set up: root-level unscoped intermediary exists, services/api scoped does NOT
rm -rf "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"
rm -rf "$CLAUDE_CAGE_CACHE/sessions"
rm -rf "$MONOREPO_PATH/.git/hooks/post-commit.d"
rm -f "$MONOREPO_PATH/.git/hooks/post-commit"
cd "$MONOREPO_PATH"
git checkout "$BRANCH_NAME"
repos_file=$(get_repos_list_path "$SOURCE_API")
rm -f "$repos_file"

# Create unscoped (root) intermediary
CLAUDE_CAGE_SESSION="test-bug5-root"
cfg_exclude=".env"
UNSCOPED_IDIR=$(get_scoped_intermediary_path "$MONOREPO_PATH" "")
create_intermediary_clone "$MONOREPO_PATH" "" >/dev/null 2>&1

# find_broader_intermediary should find the root intermediary
if ! find_broader_intermediary "$SOURCE_API" "services/api"; then
    echo "FAIL: find_broader_intermediary should find root intermediary"
    exit 1
fi

# Create sparse work dir
CLAUDE_CAGE_SESSION="test-bug5-sparse"
create_sparse_work_dir "$BROADER_INTERMEDIARY_DIR" "$BROADER_SOURCE_DIR" "services/api" "$BROADER_SCOPE_PATH" >/dev/null 2>&1

SPARSE_WORK=$(get_work_path "$MONOREPO_PATH")
if [ ! -d "$SPARSE_WORK/.git" ]; then
    echo "FAIL: Sparse work dir should exist"
    exit 1
fi

# Fix remote URL for testing (create_sparse_work_dir sets /run<path> for sandbox)
git -C "$SPARSE_WORK" remote set-url origin "$UNSCOPED_IDIR"

# Push a commit from the sparse work dir
cd "$SPARSE_WORK"
git config user.email "test@test.com"
git config user.name "Test"
echo "sparse round-trip" > services/api/app.go
git add services/api/app.go && git commit -m "Sparse round-trip commit" --quiet
sparse_commit=$(git rev-parse HEAD)
sparse_parent=$(git rev-parse HEAD^)

# Push (disable hooks to avoid pipe blocking)
rm -f "$UNSCOPED_IDIR/hooks/post-receive"
git push origin "$BRANCH_NAME" --quiet 2>/dev/null

# Sync back to source — the broader intermediary uses empty scope_path
cd "$MONOREPO_PATH"
sync_output=$(sync_to_source "$MONOREPO_PATH" "$UNSCOPED_IDIR" "refs/heads/$BRANCH_NAME" "$sparse_parent" 2>&1)

# Verify the commit applied at the correct path
source_content=$(cat "$MONOREPO_PATH/services/api/app.go" 2>/dev/null)
if [ "$source_content" != "sparse round-trip" ]; then
    echo "FAIL: Sparse round-trip commit should apply at services/api/app.go"
    echo "  Content: '$source_content'"
    echo "  sync_output: $sync_output"
    exit 1
fi
echo "  PASS: Sparse reuse round-trip sync works correctly"

echo ""
echo "=== All scoped tests passed! ==="
