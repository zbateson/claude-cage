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

echo "Test 20: enumerate_projects mounts scoped work at scope subdirectory"
# Reset session to the scoped one
CLAUDE_CAGE_SESSION="test-scoped"
cfg_isolated="false"

intermediary_root=$(get_intermediary_root)
session_work_root=$(get_session_work_root)

enumerate_projects "$session_work_root" "$intermediary_root" "$(get_work_path "$SOURCE_API")" "$INTERMEDIARY_DIR" "$SOURCE_API"

# The current project should be mounted at git_root/scope_path (= SOURCE_API)
found_scope_mount=false
for entry in "${CAGE_WORK_PROJECTS[@]}"; do
    IFS='|' read -r proj_dir mount_path <<< "$entry"
    if [ "$mount_path" = "$SOURCE_API" ]; then
        found_scope_mount=true
        break
    fi
done
if [ "$found_scope_mount" != true ]; then
    echo "FAIL: Scoped project should mount at scope path ($SOURCE_API)"
    echo "  Work projects:"
    printf '    %s\n' "${CAGE_WORK_PROJECTS[@]}"
    exit 1
fi
echo "  PASS: Scoped work mounts at scope subdirectory"

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
echo "=== Testing binary blob safety in scoped stripping ==="
echo ""

echo "Test 22: Binary blob with scope-prefix-like content survives stripping"
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
echo "=== Testing cross-scope session discovery ==="
echo ""

echo "Test 23: list_cached_sessions from git root shows scoped session"
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

echo "Test 24: list_cached_sessions from scoped dir shows unscoped session"
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

echo "Test 25: list_cached_sessions output includes source_dir and scope fields"
# Check format: session_id branch source_dir scope
line=$(echo "$sessions_from_api" | head -1)
field_count=$(echo "$line" | wc -w)
if [ "$field_count" -lt 3 ]; then
    echo "FAIL: Session line should have at least 3 fields (sid branch source_dir), got $field_count"
    echo "  Line: '$line'"
    exit 1
fi
echo "  PASS: Session output has expected field count"

echo "Test 26: find_reusable_session discovers cross-scope dirty sessions"
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
echo "=== All scoped tests passed! ==="
