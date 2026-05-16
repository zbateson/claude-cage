# ============================================================================
# Bare intermediary with history (fast-export/fast-import)
# ============================================================================

# Base directories for cage data
CLAUDE_CAGE_CACHE="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
CLAUDE_CAGE_RUNTIME="${CLAUDE_CAGE_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-cage}"

# Sanitize a branch name for use in filesystem paths
# Replaces problematic characters with dashes
sanitize_branch_name() {
    local branch="$1"
    # Replace / with -- (for feature/foo style branches)
    # Replace other problematic chars with -
    echo "$branch" | sed 's|/|--|g; s|[^a-zA-Z0-9._-]|-|g'
}

# Project key for per-project alternate sessions: <basename>-<6-char-hash>.
# The hash disambiguates same-named projects in different locations.
# Arguments: $1 = source directory
get_project_key() {
    local source_dir="$1"
    local base hash
    base=$(basename "$source_dir")
    hash=$(path_hash "$source_dir")
    echo "${base}-${hash:0:6}"
}

# Atomically claim the next available alternate-session slot for a project.
# Scans $CACHE/sessions/ for existing <project-key>-<N> dirs, picks max(N)+1
# (or 2 if none — 1 is conceptually reserved for "default"), and tries to
# claim the slot via mkdir. Retries on race if another startup beat us to it.
# Echoes the chosen cache name (e.g. "ScienceOneVue-a3f7b2-2").
# Arguments: $1 = source directory
allocate_alternate_session() {
    local source_dir="$1"
    local key
    key=$(get_project_key "$source_dir")
    local sessions_dir="$CLAUDE_CAGE_CACHE/sessions"
    mkdir -p "$sessions_dir"
    while true; do
        local max=1
        local d n
        for d in "$sessions_dir/${key}-"*; do
            [ -d "$d" ] || continue
            n="${d##*-}"
            if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$max" ]; then
                max="$n"
            fi
        done
        local next=$((max + 1))
        local candidate="$sessions_dir/${key}-${next}"
        if mkdir "$candidate" 2>/dev/null; then
            echo "${key}-${next}"
            return 0
        fi
    done
}

# Resolve a user-facing session name to its on-disk cache name.
#   "default"    → "default"
#   "session.N"  → "<project-key>-N"
# Any other input is rejected with a non-zero return and an error on stderr.
# Arguments: $1 = user-facing name, $2 = source directory
resolve_session_name() {
    local name="$1"
    local source_dir="$2"
    if [ "$name" = "default" ]; then
        echo "default"
        return 0
    elif [[ "$name" =~ ^session\.([0-9]+)$ ]]; then
        local n="${BASH_REMATCH[1]}"
        local key
        key=$(get_project_key "$source_dir")
        echo "${key}-${n}"
        return 0
    fi
    echo "error: unknown session name '$name' (expected 'default' or 'session.<N>')" >&2
    return 1
}

# Render an on-disk session cache name back to its user-facing form.
#   "default"            → "default"
#   "<basename>-<hash>-N" → "session.N"
# Anything else (legacy timestamp IDs, unknown formats) passes through verbatim
# so the caller still has something printable.
# Arguments: $1 = cache name
display_session_name() {
    local cache_id="$1"
    if [ "$cache_id" = "default" ]; then
        echo "default"
    elif [[ "$cache_id" =~ ^.+-[a-f0-9]{6}-([0-9]+)$ ]]; then
        echo "session.${BASH_REMATCH[1]}"
    else
        echo "$cache_id"
    fi
}

# Current session ID for path construction (set by main.sh before calling get_work_path)
# Format: YYYYMMDDHHMMSS timestamp
CLAUDE_CAGE_SESSION=""

# Get the work directory path for a source directory
# Get the unscoped work-dir path for a source directory in the current session.
# For scoped runs, use get_scoped_work_path instead.
# Arguments: $1 = source directory
get_work_path() {
    local source_dir="$1"
    local session_id="${CLAUDE_CAGE_SESSION:-default}"
    echo "$CLAUDE_CAGE_CACHE/sessions/$session_id/work$source_dir"
}

# Get the work-dir path with scope awareness. Mirrors the intermediary side
# (get_scoped_intermediary_path): scoped work dirs live in a separate tree
# under the session cache to prevent path collisions with unscoped siblings.
#   Unscoped (scope_path empty): $CACHE/sessions/<id>/work$source_dir/
#   Scoped:                       $CACHE/sessions/<id>/scoped$git_root/$scope_path/
# Arguments: $1 = source_dir, $2 = scope_path (optional, empty = unscoped)
get_scoped_work_path() {
    local source_dir="$1"
    local scope_path="${2:-}"
    if [ -n "$scope_path" ]; then
        local session_id="${CLAUDE_CAGE_SESSION:-default}"
        local git_root
        git_root=$(get_git_root "$source_dir")
        echo "$CLAUDE_CAGE_CACHE/sessions/$session_id/scoped${git_root}/${scope_path}"
    else
        get_work_path "$source_dir"
    fi
}

# Compute the work-dir path for an arbitrary session by path. Used by session
# enumeration that walks all sessions, not just the current one. Scope is
# inferred from source_dir vs git_root (passed in to avoid repeated git
# invocations during scans). git_root may be empty if unknown — falls back
# to treating source_dir as unscoped.
# Arguments: $1 = session_dir (full path), $2 = source_dir, $3 = git_root
session_work_dir() {
    local session_dir="$1"
    local source_dir="$2"
    local git_root="$3"
    if [ -n "$git_root" ] && [ "$source_dir" != "$git_root" ]; then
        local scope_path="${source_dir#"$git_root/"}"
        echo "$session_dir/scoped${git_root}/${scope_path}"
    else
        echo "$session_dir/work$source_dir"
    fi
}

# Variant of session_work_dir keyed on scope_path instead of git_root. Used by
# code paths that already know the scope (e.g. iterating REUSE_*_SESSIONS
# entries or persisted session lists where scope is recorded alongside source).
# Arguments: $1 = session_dir (full path), $2 = source_dir, $3 = scope_path
session_work_dir_by_scope() {
    local session_dir="$1"
    local source_dir="$2"
    local scope_path="${3:-}"
    if [ -n "$scope_path" ]; then
        echo "$session_dir/scoped${source_dir%/$scope_path}/${scope_path}"
    else
        echo "$session_dir/work$source_dir"
    fi
}

# Get the intermediary path for a source directory
# Intermediary is a bare repo shared across branches: intermediary$source_dir
# Arguments: $1 = source directory
get_intermediary_path() {
    local source_dir="$1"
    echo "$CLAUDE_CAGE_CACHE/intermediary$source_dir"
}

# Get the intermediary path with scope awareness.
# Scoped intermediaries live in a separate top-level directory to prevent
# nesting conflicts with unscoped intermediaries:
#   Unscoped: intermediary/<source_dir>  (standard path via get_intermediary_path)
#   Scoped:   scoped/<git_root>/<scope_path>
# Arguments: $1 = source_dir, $2 = scope_path (empty = unscoped, falls through to get_intermediary_path)
get_scoped_intermediary_path() {
    local source_dir="$1"
    local scope_path="${2:-}"
    if [ -n "$scope_path" ]; then
        local git_root
        git_root=$(get_git_root "$source_dir")
        echo "$CLAUDE_CAGE_CACHE/scoped${git_root}/${scope_path}/.bare"
    else
        echo "$CLAUDE_CAGE_CACHE/intermediary$source_dir"
    fi
}

# Get the commit map file path (inside bare intermediary)
# Maps intermediary hashes to source hashes
get_commit_map_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-commit-map"
}

# Get the source branches file path (inside bare intermediary)
# Lists all source branch names (for pre-receive guard)
get_source_branches_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-source-branches"
}

# Get the source marks file path (inside bare intermediary)
get_source_marks_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-source-marks"
}

# Get the import marks file path (inside bare intermediary)
get_import_marks_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-import-marks"
}

# Get the exclude hash file path (inside bare intermediary)
# Stores hash of exclude patterns to detect config changes
get_exclude_hash_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-exclude-hash"
}

# Get the pipe path for a source directory
# Uses CLAUDE_CAGE_SESSION if set
get_pipe_path() {
    local source_dir="$1"
    local session_id="${CLAUDE_CAGE_SESSION:-default}"
    echo "$CLAUDE_CAGE_RUNTIME/pipes/$session_id$source_dir"
}

# Get the session work root directory (contains all projects for a session)
# This is mounted at / so all same-session projects are visible at original paths
get_session_work_root() {
    local session_id="${CLAUDE_CAGE_SESSION:-default}"
    echo "$CLAUDE_CAGE_CACHE/sessions/$session_id/work"
}

# Get the canonical default session's work root. Every cage — default or
# alternate — uses this as the cross-project visibility tree. Alternates
# additionally overlay their own work_dir on top of their project's path
# so the project sees an isolated copy while other projects come from default.
get_default_work_root() {
    echo "$CLAUDE_CAGE_CACHE/sessions/default/work"
}

# Get the latest session file path (inside bare intermediary)
get_latest_session_path() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-latest-session"
}

# Write the latest session ID to the intermediary
write_latest_session() {
    local intermediary_dir="$1"
    local session_id="$2"
    echo "$session_id" > "$(get_latest_session_path "$intermediary_dir")"
}

# Read the latest session ID from the intermediary
# Returns empty string if not set
read_latest_session() {
    local intermediary_dir="$1"
    local path
    path=$(get_latest_session_path "$intermediary_dir")
    if [ -f "$path" ]; then
        cat "$path"
    fi
}

# Get the intermediary root directory (contains all intermediaries across all branches)
# This is mounted at /run so all intermediaries are accessible
get_intermediary_root() {
    echo "$CLAUDE_CAGE_CACHE/intermediary"
}

# Get the git root directory for a path
# Works from subdirectories by using git's auto-discovery
get_git_root() {
    local source_dir="$1"
    git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null
}

# Check if a directory is inside a git repository
# Returns 0 (success) if it is, 1 (failure) if not
is_git_repo() {
    local source_dir="$1"
    git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Check whether a git root has been touched by claude-cage before.
# Signals (any one is enough): .claude-cage config at root, repos.list entry,
# or an unscoped intermediary in $CACHE for this root. Used by main.sh to
# decide between silent subdir-routing (caged) and the fresh-repo prompt.
# Arguments: $1 = git_root directory
is_caged_repo() {
    local git_root="$1"
    [ -n "$git_root" ] || return 1
    [ -f "$git_root/.claude-cage" ] && return 0
    [ -d "$CLAUDE_CAGE_CACHE/intermediary$git_root" ] && return 0
    local repos_file
    repos_file=$(get_repos_list_path "$git_root" 2>/dev/null) || return 1
    [ -f "$repos_file" ] && return 0
    return 1
}

# Get the relative path from git root to source directory (scope path)
# Returns empty string if source_dir IS the git root
# Arguments: $1 = source directory
get_scope_path() {
    local source_dir="$1"
    local git_root
    git_root=$(get_git_root "$source_dir")
    if [ "$source_dir" = "$git_root" ]; then
        echo ""
    else
        # Use realpath to normalize, then strip git_root prefix
        local real_source real_root
        real_source=$(realpath "$source_dir")
        real_root=$(realpath "$git_root")
        echo "${real_source#"$real_root"/}"
    fi
}

# Get a hash of the git root for use in repos.list paths
# Arguments: $1 = source directory
get_git_root_hash() {
    local source_dir="$1"
    local git_root
    git_root=$(get_git_root "$source_dir")
    path_hash "$git_root"
}

# Get the repos.list file path for a git root
# Arguments: $1 = source directory
get_repos_list_path() {
    local source_dir="$1"
    local root_hash
    root_hash=$(get_git_root_hash "$source_dir")
    echo "$CLAUDE_CAGE_CACHE/repos/$root_hash"
}

# Get the scope-path metadata file path (inside bare intermediary)
get_scope_path_file() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-scope-path"
}

# Get the git-root metadata file path (inside bare intermediary)
get_git_root_file() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-git-root"
}

# Get the exclude-pathspecs metadata file path (inside bare intermediary)
get_exclude_pathspecs_file() {
    local intermediary_dir="$1"
    echo "$intermediary_dir/claude-cage-exclude-pathspecs"
}

# ============================================================================
# repos.list management (tracks scoped intermediaries per git root)
# File: $CACHE/repos/<git-root-hash> — one scope per line (empty line = root/unscoped)
# ============================================================================

# Add a scope entry to repos.list
# Arguments: $1 = source_dir, $2 = scope_path (empty for root/unscoped)
repos_list_add() {
    local source_dir="$1"
    local scope_path="${2:-}"
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")

    mkdir -p "$(dirname "$repos_file")"

    # Don't add duplicates
    if [ -f "$repos_file" ]; then
        if [ -z "$scope_path" ]; then
            # Empty pattern: grep -qxF "" matches any line, so check for empty lines explicitly
            grep -qx '^$' "$repos_file" 2>/dev/null && return
        else
            grep -qxF "$scope_path" "$repos_file" 2>/dev/null && return
        fi
    fi
    echo "$scope_path" >> "$repos_file"
}

# Remove a scope entry from repos.list
# Arguments: $1 = source_dir, $2 = scope_path (empty for root/unscoped)
repos_list_remove() {
    local source_dir="$1"
    local scope_path="${2:-}"
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")

    [ -f "$repos_file" ] || return 0

    # Remove the matching line (exact match)
    local tmp
    tmp=$(mktemp)
    if [ -z "$scope_path" ]; then
        # Empty pattern: grep -vxF "" removes all lines, so remove empty lines explicitly
        grep -v '^$' "$repos_file" > "$tmp" 2>/dev/null || true
    else
        grep -vxF "$scope_path" "$repos_file" > "$tmp" 2>/dev/null || true
    fi
    mv "$tmp" "$repos_file"

    # Clean up empty file
    if [ ! -s "$repos_file" ]; then
        rm -f "$repos_file"
    fi
}

# Print all registered scopes for a source directory
# Arguments: $1 = source_dir
# Output: one scope per line (empty line = root/unscoped)
repos_list_scopes() {
    local source_dir="$1"
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")

    [ -f "$repos_file" ] && cat "$repos_file"
}

# Check if a broader (parent) scope already exists
# Arguments: $1 = source_dir, $2 = scope_path
# Returns 0 if a parent scope exists, 1 otherwise
repos_list_has_parent() {
    local source_dir="$1"
    local scope_path="$2"
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")

    [ -f "$repos_file" ] || return 1

    while IFS= read -r existing; do
        # Empty string = root scope, which is parent of everything
        if [ -z "$existing" ]; then
            return 0
        fi
        # Check if existing is a prefix of scope_path (broader scope)
        if [ -n "$scope_path" ] && [ "$existing" != "$scope_path" ]; then
            if [[ "$scope_path" == "$existing/"* ]]; then
                return 0
            fi
        fi
    done < "$repos_file"
    return 1
}

# Clean orphaned repos.list entries (intermediary dir doesn't exist)
# Arguments: $1 = source_dir
repos_list_clean_orphans() {
    local source_dir="$1"
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")
    local git_root
    git_root=$(get_git_root "$source_dir")

    [ -f "$repos_file" ] || return 0

    local tmp
    tmp=$(mktemp)
    local kept=0
    while IFS= read -r scope; do
        local idir
        idir=$(get_scoped_intermediary_path "$git_root" "$scope")
        if [ -d "$idir" ]; then
            echo "$scope" >> "$tmp"
            kept=$((kept + 1))
        fi
    done < "$repos_file"

    if [ "$kept" -eq 0 ]; then
        rm -f "$repos_file" "$tmp"
    else
        mv "$tmp" "$repos_file"
    fi
}

# Check if a broader intermediary exists on disk for a given scope.
# Arguments: $1 = source_dir, $2 = scope_path
# Returns 0 if a real broader intermediary exists, 1 otherwise
check_broader_intermediary_exists() {
    local source_dir="$1"
    local scope_path="$2"
    [ -n "$scope_path" ] || return 1

    local git_root
    git_root=$(get_git_root "$source_dir")
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")
    [ -f "$repos_file" ] || return 1

    while IFS= read -r _existing_scope; do
        local _is_parent=false
        if [ -z "$_existing_scope" ]; then
            _is_parent=true
        elif [[ "$scope_path" == "$_existing_scope/"* ]]; then
            _is_parent=true
        fi
        if [ "$_is_parent" = true ]; then
            local _parent_idir
            _parent_idir=$(get_scoped_intermediary_path "$git_root" "$_existing_scope")
            if [ -d "$_parent_idir" ] && [ -f "$_parent_idir/HEAD" ]; then
                return 0
            fi
        fi
    done < "$repos_file"
    return 1
}

# Remove narrower child scoped intermediaries that are subsets of the given scope.
# Skips children with active sessions (checked via has_any_sessions).
# Arguments: $1 = source_dir (at git root or broader scope), $2 = scope_path being created
cleanup_child_intermediaries() {
    local source_dir="$1"
    local scope_path="${2:-}"

    local git_root
    git_root=$(get_git_root "$source_dir")
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")
    [ -f "$repos_file" ] || return 0

    local children_to_remove=()
    while IFS= read -r _existing_scope; do
        # Skip self
        [ "$_existing_scope" = "$scope_path" ] && continue
        # Check if _existing_scope is a child of scope_path
        local _is_child=false
        if [ -z "$scope_path" ]; then
            # Root scope: everything else is a child
            [ -n "$_existing_scope" ] && _is_child=true
        elif [[ "$_existing_scope" == "$scope_path/"* ]]; then
            _is_child=true
        fi
        if [ "$_is_child" = true ]; then
            local child_source_dir="$git_root/$_existing_scope"
            # Skip if child has active sessions
            if has_any_sessions "$child_source_dir"; then
                echo "  Skippin' cleanup of $_existing_scope — active session"
                continue
            fi
            local child_idir
            child_idir=$(get_scoped_intermediary_path "$git_root" "$_existing_scope")
            if [ -d "$child_idir" ]; then
                rm -rf "$child_idir"
                echo "  Cleaned up narrower scope: $_existing_scope"
                cleanup_empty_parents "$child_idir" "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE"
            fi
            children_to_remove+=("$_existing_scope")
        fi
    done < "$repos_file"

    # Remove children from repos.list
    for child in "${children_to_remove[@]}"; do
        repos_list_remove "$source_dir" "$child"
    done
}

# Deferred cleanup: remove a scoped intermediary if a broader scope now exists.
# Called on session exit when the narrower scope is no longer needed.
# Arguments: $1 = source_dir, $2 = scope_path
maybe_cleanup_superseded_intermediary() {
    local source_dir="$1"
    local scope_path="$2"
    [ -n "$scope_path" ] || return 0

    # Don't clean up if other sessions still use this scope
    if has_any_sessions "$source_dir"; then
        return 0
    fi

    # Check if a broader scope exists
    if ! check_broader_intermediary_exists "$source_dir" "$scope_path"; then
        return 0
    fi

    local git_root
    git_root=$(get_git_root "$source_dir")
    local idir
    idir=$(get_scoped_intermediary_path "$git_root" "$scope_path")
    if [ -d "$idir" ]; then
        rm -rf "$idir"
        cleanup_empty_parents "$idir" "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE"
        repos_list_remove "$source_dir" "$scope_path"
        echo "Cleaned up scoped intermediary: $scope_path (broader scope covers it now)"
    fi
}

# Build a list of source directories across all scopes for a git root.
# Sets: _CROSS_SCOPE_SOURCE_DIRS array
build_cross_scope_source_dirs() {
    local source_dir="$1"
    _CROSS_SCOPE_SOURCE_DIRS=("$source_dir")
    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null) || true
    [ -z "$git_root" ] && return
    local repos_file
    repos_file=$(get_repos_list_path "$source_dir")
    [ -f "$repos_file" ] || return 0
    while IFS= read -r _scope; do
        local _sd
        if [ -z "$_scope" ]; then _sd="$git_root"; else _sd="$git_root/$_scope"; fi
        local _dup=false _e
        for _e in "${_CROSS_SCOPE_SOURCE_DIRS[@]}"; do
            [ "$_e" = "$_sd" ] && _dup=true && break
        done
        [ "$_dup" = false ] && _CROSS_SCOPE_SOURCE_DIRS+=("$_sd")
    done < "$repos_file"
}

# List all cached sessions for a source directory (newest first)
# Discovers sessions across all scopes in the same git root via repos.list.
# Output: one line per session: "<session_id> <branch> <source_dir> <scope>"
# (scope is empty for unscoped sessions — naturally handled by read -r)
list_cached_sessions() {
    local source_dir="$1"
    build_cross_scope_source_dirs "$source_dir"
    local -a source_dirs=("${_CROSS_SCOPE_SOURCE_DIRS[@]}")

    local our_git_root
    our_git_root=$(get_git_root "$source_dir" 2>/dev/null) || our_git_root=""

    # Scan sessions for all discovered source dirs
    if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        local session_id sd
        for session_dir in $(ls -1dr "$CLAUDE_CAGE_CACHE/sessions"/* 2>/dev/null); do
            [ -d "$session_dir" ] || continue
            session_id=$(basename "$session_dir")
            for sd in "${source_dirs[@]}"; do
                local work
                work=$(session_work_dir "$session_dir" "$sd" "$our_git_root")
                # Must have .git to be a real work dir
                if [ -d "$work/.git" ]; then
                    local branch scope=""
                    branch=$(get_work_branch "$work")
                    [ -f "$work/.git/claude-cage-scope-path" ] && \
                        scope=$(cat "$work/.git/claude-cage-scope-path")
                    echo "$session_id $branch $sd $scope"
                fi
            done
        done
    fi
}

# Render contextual information about a dirty session for the pick-it-up prompt.
# Shows up to three subsections (each printed only if it has content):
#   1) Latest synced commit from source — the divergence point.
#   2) Unpushed commits in the cage — what's been done but not yet propagated.
#   3) Workspace state — current uncommitted changes (git status --short).
# Subsection 2 and 3 are each truncated to 20 lines with an "... and N more"
# tail. Defensive: any failing subsection is silently skipped so the prompt
# still works on damaged work dirs.
# Arguments: $1 = source_dir, $2 = work_dir, $3 = branch (e.g. "master")
print_session_context() {
    local source_dir="$1"
    local work_dir="$2"
    local branch="$3"
    local max_lines=20

    # 1) Latest synced commit from source
    if [ -d "$source_dir/.git" ] || [ -d "$source_dir" ] && git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        local _source_head
        _source_head=$(git -C "$source_dir" log --oneline -1 2>/dev/null)
        if [ -n "$_source_head" ]; then
            echo ""
            echo "Latest synced commit (from source):"
            echo "  $_source_head"
        fi
    fi

    # 2) Unpushed commits in the cage (intermediary is the cage's origin, so
    # origin/<branch>..HEAD lists what hasn't propagated back yet).
    if [ -d "$work_dir/.git" ] && [ -n "$branch" ]; then
        local _unpushed
        _unpushed=$(git -C "$work_dir" log --oneline "origin/$branch..HEAD" 2>/dev/null)
        if [ -n "$_unpushed" ]; then
            local _total
            _total=$(echo "$_unpushed" | wc -l)
            echo ""
            echo "Unpushed commits in cage (not yet in source):"
            echo "$_unpushed" | head -n "$max_lines" | sed 's/^/  /'
            if [ "$_total" -gt "$max_lines" ]; then
                echo "  ... and $((_total - max_lines)) more"
            fi
        fi
    fi

    # 3) Workspace state (compact porcelain)
    if [ -d "$work_dir/.git" ]; then
        git -C "$work_dir" update-index --refresh -q --unmerged >/dev/null 2>&1 || true
        local _status
        _status=$(git -C "$work_dir" status --short 2>/dev/null)
        if [ -n "$_status" ]; then
            local _total
            _total=$(echo "$_status" | wc -l)
            echo ""
            echo "Workspace state:"
            echo "$_status" | head -n "$max_lines" | sed 's/^/  /'
            if [ "$_total" -gt "$max_lines" ]; then
                echo "  ... and $((_total - max_lines)) more"
            fi
        fi
    fi
}

# Check if a work directory has uncommitted changes
# Returns 0 if dirty, 1 if clean
# Refreshes the stat cache before reading porcelain so stale mtime/size from
# suspend/resume, file-mode flips, or backup restores doesn't fake a "dirty"
# result. The refresh is silent on the happy path and idempotent.
is_work_dirty() {
    local work_dir="$1"
    [ -d "$work_dir/.git" ] || return 1
    git -C "$work_dir" update-index --refresh -q --unmerged >/dev/null 2>&1 || true
    if [ -n "$(git -C "$work_dir" status --porcelain 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# Check if a work directory has unpushed commits
# Returns 0 if unpushed exist, 1 if all pushed (or not a git repo)
work_has_unpushed() {
    local work_dir="$1"
    [ -d "$work_dir/.git" ] || return 1
    local branch
    branch=$(git -C "$work_dir" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && return 1
    # Check if origin/<branch> exists
    if ! git -C "$work_dir" rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        # No tracking branch — if there are commits, they're unpushed
        local count
        count=$(git -C "$work_dir" rev-list --count HEAD 2>/dev/null) || return 1
        [ "$count" -gt 0 ]
        return
    fi
    # Check for unpushed commits
    local ahead
    ahead=$(git -C "$work_dir" rev-list --count "origin/$branch..HEAD" 2>/dev/null) || return 1
    [ "$ahead" -gt 0 ]
}

# Get the current branch of a work directory
get_work_branch() {
    local work_dir="$1"
    git -C "$work_dir" branch --show-current 2>/dev/null
}

# List inactive dirty alternate sessions for a project. Scans
# $CACHE/sessions/<project-key>-<N> dirs, skipping the ones with a live PID,
# and reports the ones whose work tree is dirty (uncommitted or unpushed).
# Output format (one line per alternate):
#   <session_id> <branch> <dirty_type> <source_dir> <scope>
# dirty_type ∈ {uncommitted, unpushed, uncommitted+unpushed}.
# Arguments: $1 = source_dir
list_inactive_dirty_alternates() {
    local source_dir="$1"
    local sessions_dir="$CLAUDE_CAGE_CACHE/sessions"
    [ -d "$sessions_dir" ] || return 0

    local key
    key=$(get_project_key "$source_dir")
    local our_git_root
    our_git_root=$(get_git_root "$source_dir" 2>/dev/null) || our_git_root=""

    local d session_id work branch scope
    # Newest first via sort -r on the numeric suffix
    for d in $(ls -1d "$sessions_dir/${key}-"* 2>/dev/null | awk -F- '{print $NF" "$0}' | sort -rn | awk '{print $2}'); do
        [ -d "$d" ] || continue
        session_id=$(basename "$d")
        # Skip active alternates
        session_is_active "$session_id" && continue

        work=$(session_work_dir "$d" "$source_dir" "$our_git_root")
        [ -d "$work/.git" ] || continue

        branch=$(get_work_branch "$work")
        scope=""
        [ -f "$work/.git/claude-cage-scope-path" ] && \
            scope=$(cat "$work/.git/claude-cage-scope-path")

        local has_uncommitted=false has_unpushed=false dirty_type=""
        is_work_dirty "$work" && has_uncommitted=true
        work_has_unpushed "$work" && has_unpushed=true
        if [ "$has_uncommitted" = true ] && [ "$has_unpushed" = true ]; then
            dirty_type="uncommitted+unpushed"
        elif [ "$has_uncommitted" = true ]; then
            dirty_type="uncommitted"
        elif [ "$has_unpushed" = true ]; then
            dirty_type="unpushed"
        fi
        [ -n "$dirty_type" ] && echo "$session_id $branch $dirty_type $source_dir $scope"
    done
}

# Single entry point for session selection. Replaces the previous find +
# reuse_or_create_session + dispatch flow with a much smaller decision tree:
#
#   1) --attach-session set → resolve user-facing name to cache id, verify
#      it exists; for the no-arg form, prompt across attachable sessions.
#   2) "default" has no live PID for this source_dir → land in "default".
#   3) Otherwise we need an alternate:
#      - Interactive + at least one inactive dirty alternate for this project
#        → prompt: pick it up, or start fresh.
#      - Otherwise → allocate a brand-new alternate slot.
#
# Sets CLAUDE_CAGE_SESSION (and, when picking up an existing alternate,
# crosses to that alternate's source/scope if it differs).
# Arguments: $1 = source_dir
select_session() {
    local source_dir="$1"

    if [ "${cli_attach_session_mode:-false}" = true ]; then
        _select_attach_session "$source_dir"
        return
    fi

    if ! session_is_active_for_source "default" "$source_dir"; then
        CLAUDE_CAGE_SESSION="default"
        return
    fi

    local _alternates
    _alternates=$(list_inactive_dirty_alternates "$source_dir")
    if [ -n "$_alternates" ] && [ -t 0 ] && [ -t 1 ]; then
        _select_alternate_prompt "$source_dir" "$_alternates"
        return
    fi

    CLAUDE_CAGE_SESSION=$(allocate_alternate_session "$source_dir")
    echo "Settin' up $(display_session_name "$CLAUDE_CAGE_SESSION") (this project's already runnin' in default)."
}

# Helper for select_session: handle --attach-session in both forms (specific
# user-facing name, or no-arg → prompt over attachable sessions).
# Arguments: $1 = source_dir
_select_attach_session() {
    local source_dir="$1"

    if [ -n "${cli_attach_session:-}" ]; then
        # Specific name. Accept "default", "session.N", or a legacy cache id
        # (timestamp form) for users mid-migration.
        local cache_id
        if cache_id=$(resolve_session_name "$cli_attach_session" "$source_dir" 2>/dev/null); then
            :
        else
            cache_id="$cli_attach_session"
        fi
        if [ "$cache_id" = "default" ]; then
            CLAUDE_CAGE_SESSION="default"
            echo "Attachin' to the default session."
            return
        fi
        if [ ! -d "$CLAUDE_CAGE_CACHE/sessions/$cache_id" ]; then
            echo "No session named '$cli_attach_session'." >&2
            exit 1
        fi
        CLAUDE_CAGE_SESSION="$cache_id"
        echo "Attachin' to $(display_session_name "$cache_id")."
        return
    fi

    # No-arg --attach-session: build the list of attachable sessions
    # (default + each on-disk alternate for this project). Prompt if many.
    local key
    key=$(get_project_key "$source_dir")
    local -a candidates=()
    [ -d "$CLAUDE_CAGE_CACHE/sessions/default" ] && candidates+=("default")
    local d
    for d in $(ls -1d "$CLAUDE_CAGE_CACHE/sessions/${key}-"* 2>/dev/null | awk -F- '{print $NF" "$0}' | sort -n | awk '{print $2}'); do
        [ -d "$d" ] || continue
        candidates+=("$(basename "$d")")
    done

    if [ ${#candidates[@]} -eq 0 ]; then
        echo "No sessions to attach to." >&2
        exit 1
    fi

    if [ ${#candidates[@]} -eq 1 ]; then
        CLAUDE_CAGE_SESSION="${candidates[0]}"
        echo "Attachin' to $(display_session_name "$CLAUDE_CAGE_SESSION")."
        return
    fi

    echo "Multiple sessions available:"
    echo ""
    local i=1
    for cid in "${candidates[@]}"; do
        local marker=""
        session_is_active "$cid" && marker=" (active)"
        echo "  $i) $(display_session_name "$cid")${marker}"
        i=$((i + 1))
    done
    echo ""
    while true; do
        printf "Which session do you wanna attach to? "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#candidates[@]} ]; then
            CLAUDE_CAGE_SESSION="${candidates[$((choice - 1))]}"
            return
        fi
        echo "Pick a number."
    done
}

# Helper for select_session: prompt the user over inactive dirty alternates
# for this project. Each candidate gets a number; "n" → fresh alternate; "q" → quit.
# Picking an alternate may switch source_dir/scope to that alternate's, so
# we update the relevant globals (cfg_source, scope_path, intermediary_dir).
# Arguments: $1 = source_dir, $2 = newline-separated alternate list
_select_alternate_prompt() {
    local source_dir="$1"
    local alternates="$2"

    local count
    count=$(echo "$alternates" | wc -l)

    echo "This project's already runnin' in 'default'. Found $count inactive cage(s) with dirty work:"
    echo ""
    local -a alt_entries=()
    local -a alt_ids=()
    local idx=1
    local sid branch dtype dsource dscope dirty_label scope_label
    while IFS=' ' read -r sid branch dtype dsource dscope; do
        alt_entries+=("$sid $branch $dtype $dsource $dscope")
        alt_ids+=("$sid")
        dirty_label="uncommitted changes"
        case "$dtype" in
            unpushed) dirty_label="unpushed commits" ;;
            uncommitted+unpushed) dirty_label="uncommitted changes + unpushed commits" ;;
        esac
        scope_label=""
        [ -n "$dscope" ] && scope_label=" ${_cyan}(scoped: $dscope)${_reset}"
        printf "  %d) %s  branch: %-20s (%s)%b\n" "$idx" "$(display_session_name "$sid")" "$branch" "$dirty_label" "$scope_label"
        idx=$((idx + 1))
    done <<< "$alternates"

    # Surface the latest alternate's git context so the user has something
    # concrete to evaluate before picking. print_session_context handles
    # missing pieces gracefully.
    IFS=' ' read -r _latest_sid _latest_branch _latest_dtype _latest_source _latest_scope <<< "${alt_entries[0]}"
    local _alt_work
    _alt_work=$(session_work_dir_by_scope "$CLAUDE_CAGE_CACHE/sessions/$_latest_sid" "$_latest_source" "$_latest_scope")
    echo ""
    echo "Latest alternate ($(display_session_name "$_latest_sid")):"
    print_session_context "$_latest_source" "$_alt_work" "$_latest_branch"
    echo ""
    echo "What do you wanna do?"
    echo "  Pick a number to pick that alternate up, or:"
    echo "  n) Start fresh (new alternate)"
    echo "  q) Quit"
    echo ""

    while true; do
        printf "Choice: "
        read -r choice
        case "$choice" in
            n|N)
                CLAUDE_CAGE_SESSION=$(allocate_alternate_session "$source_dir")
                echo "Settin' up $(display_session_name "$CLAUDE_CAGE_SESSION")."
                return
                ;;
            q|Q) echo "Catch you later."; exit 0 ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#alt_ids[@]} ]; then
                    local _sel_sid _sel_branch _sel_dtype _sel_source _sel_scope
                    read -r _sel_sid _sel_branch _sel_dtype _sel_source _sel_scope \
                        <<< "${alt_entries[$((choice - 1))]}"
                    CLAUDE_CAGE_SESSION="$_sel_sid"
                    # Cross-scope override: if the dirty alternate lives under a
                    # different scope than this invocation, follow it.
                    if [ "$_sel_source" != "$source_dir" ]; then
                        cfg_source="$_sel_source"
                        scope_path="${_sel_scope:-}"
                        intermediary_dir=$(get_scoped_intermediary_path "$cfg_source" "$scope_path")
                    fi
                    return
                fi
                echo "Pick a number, n, or q."
                ;;
        esac
    done
}

# Tear down the current session's work dir, empty session-cache layers, and
# its .caged sidecar. Called from cleanup_on_exit when we've determined the
# cage is safe to drop (clean tree or dirty-but-matched-source).
# Arguments: $1 = source directory
# Uses globals: work_dir, CLAUDE_CAGE_CACHE, CLAUDE_CAGE_SESSION
cleanup_current_session_workdir() {
    local source_dir="$1"
    local session_cache="$CLAUDE_CAGE_CACHE/sessions/$CLAUDE_CAGE_SESSION"

    rm -rf "$work_dir"
    # Walk up to either tree's root (work/ for unscoped, scoped/ for scoped runs)
    cleanup_empty_parents "$work_dir" "$session_cache/work" "$session_cache/scoped" "$session_cache"

    if [ -d "$session_cache/work" ] && [ -z "$(ls -A "$session_cache/work" 2>/dev/null)" ]; then
        rm -rf "$session_cache/work"
    fi
    if [ -d "$session_cache/scoped" ] && [ -z "$(ls -A "$session_cache/scoped" 2>/dev/null)" ]; then
        rm -rf "$session_cache/scoped"
    fi
    if [ -d "$session_cache" ] && [ -z "$(ls -A "$session_cache" 2>/dev/null)" ]; then
        rm -rf "$session_cache"
        local _log_file="$CLAUDE_CAGE_CACHE/logs/$CLAUDE_CAGE_SESSION.log"
        [ -f "$_log_file" ] && rm -f "$_log_file"
    fi

    local _git_root
    _git_root=$(get_git_root "$source_dir") || true
    if [ -n "$_git_root" ]; then
        local _display_name
        _display_name=$(display_session_name "$CLAUDE_CAGE_SESSION")
        [ -d "$_git_root/.caged/sessions/$_display_name" ] && \
            rm -rf "$_git_root/.caged/sessions/$_display_name"
        # Defensive: also remove the cache-id path if a previous run left one
        [ "$_display_name" != "$CLAUDE_CAGE_SESSION" ] && \
            [ -d "$_git_root/.caged/sessions/$CLAUDE_CAGE_SESSION" ] && \
            rm -rf "$_git_root/.caged/sessions/$CLAUDE_CAGE_SESSION"
    fi
}

# Prune .caged/sessions/<id>/ dirs whose work symlink target no longer exists.
# Handles sessions cleaned up externally (cross-project sweeps, manual rm, crashes)
# without removing the .caged sidecar.
# Arguments: $1 = source directory
cleanup_stale_caged_links() {
    local source_dir="$1"
    [ "${dry_run:-}" = true ] && return 0

    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null) || return 0
    [ -z "$git_root" ] && return 0

    local sessions_dir="$git_root/.caged/sessions"
    [ -d "$sessions_dir" ] || return 0

    local cleaned=0
    local entry work_link
    for entry in "$sessions_dir"/*; do
        [ -d "$entry" ] || continue
        work_link="$entry/work"
        if [ ! -L "$work_link" ] || [ ! -e "$work_link" ]; then
            rm -rf "$entry"
            cleaned=$((cleaned + 1))
        fi
    done

    if [ -d "$sessions_dir" ] && [ -z "$(ls -A "$sessions_dir" 2>/dev/null)" ]; then
        rmdir "$sessions_dir" 2>/dev/null || true
    fi

    local caged_dir="$git_root/.caged"
    if [ -d "$caged_dir" ]; then
        local remaining
        remaining=$(ls -A "$caged_dir" 2>/dev/null | grep -v '^\.gitignore$')
        if [ -z "$remaining" ]; then
            rm -rf "$caged_dir"
        fi
    fi

    if [ "$cleaned" -gt 0 ]; then
        echo "Cleaned up $cleaned stale .caged session link(s)."
    fi
}

# Check if a specific session has any live PID (any project)
# Arguments: $1 = session_id
session_is_active() {
    local session_id="$1"
    local session_dir="$CLAUDE_CAGE_RUNTIME/sessions/$session_id"

    [ -d "$session_dir" ] || return 1

    for pidfile in "$session_dir"/*; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(basename "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Check if a specific session has a live PID for a specific source_dir
# Arguments: $1 = session_id, $2 = source_dir
session_is_active_for_source() {
    local session_id="$1"
    local source_dir="$2"
    local session_dir="$CLAUDE_CAGE_RUNTIME/sessions/$session_id"

    [ -d "$session_dir" ] || return 1

    for pidfile in "$session_dir"/*; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(basename "$pidfile")
        local file_source
        file_source=$(cat "$pidfile" 2>/dev/null)
        if [ "$file_source" = "$source_dir" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Clean up cache for a specific session
# Only removes this project's work dir from the session.
# Removes session dir only if empty after cleanup.
# Arguments: $1 = source directory, $2 = session_id (timestamp)
clean_session_cache() {
    local source_dir="$1"
    local session_id="$2"
    local session_cache="$CLAUDE_CAGE_CACHE/sessions/$session_id"

    # Determine scope and work dir. Try unscoped path first; if that's not a
    # work dir but a scoped tree exists, look there. Scope metadata lives in
    # the work dir's .git folder.
    local work_dir="$session_cache/work$source_dir"
    local _clean_scope=""
    if [ -f "$work_dir/.git/claude-cage-scope-path" ]; then
        _clean_scope=$(cat "$work_dir/.git/claude-cage-scope-path")
    elif [ ! -d "$work_dir/.git" ] && [ -d "$session_cache/scoped" ]; then
        # Look for a scoped work dir under this session whose source_dir matches
        local _candidate
        while IFS= read -r _candidate; do
            local _meta="$_candidate/claude-cage-scope-path"
            [ -f "$_meta" ] || continue
            local _scope
            _scope=$(cat "$_meta")
            # Reconstruct source path: $session_cache/scoped$git_root/$scope
            local _candidate_work="${_candidate%/.git}"
            local _candidate_src="${_candidate_work#"$session_cache/scoped"}"
            if [ "$_candidate_src" = "$source_dir" ]; then
                work_dir="$_candidate_work"
                _clean_scope="$_scope"
                break
            fi
        done < <(find "$session_cache/scoped" -name .git -type d 2>/dev/null)
    fi

    local intermediary_dir
    intermediary_dir=$(get_scoped_intermediary_path "$source_dir" "$_clean_scope")
    local _clean_display
    _clean_display=$(display_session_name "$session_id")
    local caged_link="$source_dir/.caged/sessions/$_clean_display"

    # Remove source hooks for this project (only if no other sessions active)
    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null)
    if [ -n "$git_root" ]; then
        local _ph
        _ph=$(path_hash "$source_dir")
        local post_commit_hook="$git_root/.git/hooks/post-commit.d/claude-cage-$_ph"
        local post_merge_hook="$git_root/.git/hooks/post-merge.d/claude-cage-$_ph"

        if ! has_other_sessions "$source_dir"; then
            if [ -f "$post_commit_hook" ]; then
                run rm -f "$post_commit_hook"
                echo "Removed post-commit hook: $post_commit_hook"
                maybe_remove_dispatcher "$git_root" "post-commit"
            fi
            if [ -f "$post_merge_hook" ]; then
                run rm -f "$post_merge_hook"
                echo "Removed post-merge hook: $post_merge_hook"
                maybe_remove_dispatcher "$git_root" "post-merge"
            fi
        fi
    fi

    # Remove work directory
    if [ -d "$work_dir" ]; then
        run rm -rf "$work_dir"
        echo "Removed work directory: $work_dir"
    fi

    # Remove .caged symlink for this session
    if [ -d "$caged_link" ]; then
        run rm -rf "$caged_link"
        echo "Removed .caged symlink: $caged_link"
    fi

    # Clean up empty parent directories within whichever tree contains work_dir
    cleanup_empty_parents "$work_dir" "$session_cache/work" "$session_cache/scoped" "$session_cache"

    # Clean up empty tree roots and the session directory itself
    if [ -d "$session_cache/work" ] && [ -z "$(ls -A "$session_cache/work" 2>/dev/null)" ]; then
        run rm -rf "$session_cache/work"
    fi
    if [ -d "$session_cache/scoped" ] && [ -z "$(ls -A "$session_cache/scoped" 2>/dev/null)" ]; then
        run rm -rf "$session_cache/scoped"
    fi
    if [ -d "$session_cache" ] && [ -z "$(ls -A "$session_cache" 2>/dev/null)" ]; then
        run rm -rf "$session_cache"
        echo "Removed empty session cache: $session_cache"
    fi

    # Remove session log only if session dir is fully gone
    if [ ! -d "$session_cache" ]; then
        local log_file="$CLAUDE_CAGE_CACHE/logs/$session_id.log"
        if [ -f "$log_file" ]; then
            run rm -f "$log_file"
            echo "Removed session log: $log_file"
        fi
    fi

    # Check if shared intermediary should be removed
    # Only remove if no other sessions use it (no work dirs reference this
    # source). For scoped sessions, check the scoped tree; for unscoped, the
    # standard work-tree path.
    local other_sessions_exist=false
    if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        local _other_work_path
        for sd in "$CLAUDE_CAGE_CACHE/sessions"/*; do
            [ -d "$sd" ] || continue
            if [ -n "$_clean_scope" ]; then
                _other_work_path="$sd/scoped${source_dir%/$_clean_scope}/${_clean_scope}/.git"
            else
                _other_work_path="$sd/work$source_dir/.git"
            fi
            if [ -d "$_other_work_path" ]; then
                other_sessions_exist=true
                break
            fi
        done
    fi

    if [ "$other_sessions_exist" = false ] && [ -d "$intermediary_dir" ]; then
        # Read scope_path before removing intermediary (for repos.list cleanup)
        local scope_path=""
        local scope_path_file
        scope_path_file=$(get_scope_path_file "$intermediary_dir")
        if [ -f "$scope_path_file" ]; then
            scope_path=$(cat "$scope_path_file")
        fi

        run rm -rf "$intermediary_dir"
        echo "Removed shared intermediary: $intermediary_dir"

        # Remove from repos.list
        repos_list_remove "$source_dir" "$scope_path"

        # Clean up empty parent dirs
        cleanup_empty_parents "$intermediary_dir" "$CLAUDE_CAGE_CACHE/intermediary" "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE"
    fi

    # Remove empty top-level cache dirs (scoped/ and intermediary/)
    local _top_dir
    for _top_dir in "$CLAUDE_CAGE_CACHE/scoped" "$CLAUDE_CAGE_CACHE/intermediary"; do
        if [ -d "$_top_dir" ] && [ -z "$(ls -A "$_top_dir" 2>/dev/null)" ]; then
            run rm -rf "$_top_dir"
        fi
    done

    # Clean up empty .caged directory
    local caged_dir="$source_dir/.caged"
    if [ -d "$caged_dir" ]; then
        local remaining
        remaining=$(ls -A "$caged_dir" 2>/dev/null | grep -v '^\.gitignore$')
        if [ -z "$remaining" ]; then
            run rm -rf "$caged_dir"
            echo "Removed empty .caged directory"
        fi
    fi

    # Clean up empty logs directory
    if [ -d "$CLAUDE_CAGE_CACHE/logs" ] && [ -z "$(ls -A "$CLAUDE_CAGE_CACHE/logs" 2>/dev/null)" ]; then
        run rm -rf "$CLAUDE_CAGE_CACHE/logs"
    fi
}

# Install the scope-prefix-stripping script into the intermediary.
# This is the single source of truth for the binary-safe awk logic that
# strips scope prefixes from fast-export stream paths. Called once during
# intermediary setup; invoked by strip_scope_prefix() and the post-commit hook.
# Arguments: $1 = intermediary_dir
install_strip_prefix_script() {
    local intermediary_dir="$1"
    cat > "$intermediary_dir/claude-cage-strip-prefix" << 'STRIPEOF'
#!/bin/sh
# Strip a path prefix from fast-export stream M/D/R/C lines (in-place).
# Binary-safe: tracks "data N" byte counts to skip over blob/message content
# so only actual path operation lines are modified.
# Usage: claude-cage-strip-prefix <prefix> <file>
PREFIX="$1"
FILE="$2"
TMP="${FILE}.strip-tmp"
LC_ALL=C awk -v prefix="$PREFIX" '
BEGIN { OFS = " "; dr = 0; plen = length(prefix) }
{
    # Inside a data section: pass through, count bytes consumed
    # (length + 1 accounts for the newline awk consumed as RS)
    if (dr > 0) { print; dr -= length($0) + 1; next }

    # "data N" starts a data section — pass through, enter byte-counting mode
    if (/^data [0-9]+$/) { dr = substr($0, 6) + 0; print; next }

    # Strip prefix from M/D/R/C path fields.
    # Paths may be C-quoted ("path") when they contain high-bit bytes, tabs,
    # backslashes, or double-quotes. Check for both unquoted and quoted forms.
    if ($1 == "M" && NF >= 4) {
        if (substr($4, 1, plen) == prefix)
            $4 = substr($4, plen + 1)
        else if (substr($4, 1, 1) == "\"" && substr($4, 2, plen) == prefix)
            $4 = "\"" substr($4, plen + 2)
    }
    else if ($1 == "D" && NF >= 2) {
        if (substr($2, 1, plen) == prefix)
            $2 = substr($2, plen + 1)
        else if (substr($2, 1, 1) == "\"" && substr($2, 2, plen) == prefix)
            $2 = "\"" substr($2, plen + 2)
    }
    else if (($1 == "R" || $1 == "C") && NF >= 3) {
        if (substr($2, 1, plen) == prefix) $2 = substr($2, plen + 1)
        else if (substr($2, 1, 1) == "\"" && substr($2, 2, plen) == prefix)
            $2 = "\"" substr($2, plen + 2)
        if (substr($3, 1, plen) == prefix) $3 = substr($3, plen + 1)
        else if (substr($3, 1, 1) == "\"" && substr($3, 2, plen) == prefix)
            $3 = "\"" substr($3, plen + 2)
    }
    print
}
' "$FILE" > "$TMP" && mv "$TMP" "$FILE"
STRIPEOF
    chmod +x "$intermediary_dir/claude-cage-strip-prefix"
}

# Install the per-commit sync helper script into the intermediary.
# This is the single source of truth for syncing one source commit to the intermediary
# via fast-export/fast-import with pathspec excludes. Called by both post-commit and
# post-merge hooks on the source repo.
# Arguments: $1 = intermediary_dir
install_sync_commit_script() {
    local intermediary_dir="$1"
    cat > "$intermediary_dir/claude-cage-sync-commit" << 'SYNCEOF'
#!/bin/bash
# Sync a single source commit to the intermediary via fast-export/fast-import.
# Called by post-commit and post-merge hooks on the source repo.
# Arguments: $1 = commit hash to sync
# Required environment variables (set by calling hook):
#   INTERMEDIARY, SOURCE_MARKS, IMPORT_MARKS, COMMIT_MAP, SYNC_LOG
#   SCOPE_PATH, SCOPE_LABEL, EXCLUDE_PATHSPECS_FILE
COMMIT_HASH="$1"
COMMIT_SHORT="${COMMIT_HASH:0:8}"

_sync_log() {
    printf '[%s] %s %-14s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$3" >> "$SYNC_LOG"
}

SUBJECT=$(git log -1 --format=%s "$COMMIT_HASH" | head -c 50)
_sync_log "$COMMIT_SHORT" ">>intermediary" "applying: $SUBJECT"

# Build combined pathspec: scope include + exclude (read from metadata file at runtime)
PATHSPEC_ARGS=()
[ -n "$SCOPE_PATH" ] && PATHSPEC_ARGS+=("$SCOPE_PATH/")
if [ -f "$EXCLUDE_PATHSPECS_FILE" ]; then
    while IFS= read -r _ps; do
        [ -n "$_ps" ] && PATHSPEC_ARGS+=("$_ps")
    done < "$EXCLUDE_PATHSPECS_FILE"
fi

EXPORT_ERR=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-err.$$")
EXPORT_OUT=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-export-out.$$")

# Determine branch for this commit (needed for ref rewriting and marks-gap injection)
current_branch=$(git branch --show-current 2>/dev/null)
# If detached or branch detection fails, try to find which branch contains this commit
if [ -z "$current_branch" ]; then
    current_branch=$(git branch --contains "$COMMIT_HASH" 2>/dev/null | head -1 | sed 's/^[ *]*//')
fi

# For merge commits, ensure all parents have marks in source-marks before fast-export.
# If a parent was synced via sync_to_source (git-am path), its mark may be missing from
# source-marks. Without it, fast-export misattributes the from line (uses the second
# parent) and the merge topology is lost, causing non-fast-forward errors on import.
if git rev-parse --verify "${COMMIT_HASH}^2" >/dev/null 2>&1; then
    for _PARENT_HASH in $(git rev-list --parents -1 "$COMMIT_HASH" | cut -d' ' -f2-); do
        if [ -f "$SOURCE_MARKS" ] && grep -q " ${_PARENT_HASH}$" "$SOURCE_MARKS" 2>/dev/null; then
            continue
        fi
        # Parent not in source-marks — look up its intermediary hash from commit map
        _INT_PARENT=$(awk -v sh="$_PARENT_HASH" '$2 == sh && $1 != "0" { print $1; exit }' "$COMMIT_MAP" 2>/dev/null)
        if [ -n "$_INT_PARENT" ] && [ -f "$SOURCE_MARKS" ] && [ -f "$IMPORT_MARKS" ]; then
            _MAX_MARK=$(awk '{ gsub(/^:/,"",$1); id=$1+0; if(id>m) m=id } END { print m+0 }' \
                "$SOURCE_MARKS" "$IMPORT_MARKS" 2>/dev/null)
            _NEW_MARK=$((_MAX_MARK + 1))
            echo ":$_NEW_MARK $_PARENT_HASH" >> "$SOURCE_MARKS"
            echo ":$_NEW_MARK $_INT_PARENT" >> "$IMPORT_MARKS"
            _sync_log "$COMMIT_SHORT" ">>intermediary" "added missing parent mark :$_NEW_MARK for ${_PARENT_HASH:0:8}"
        fi
    done
fi

# Export to temp file first so we can detect excluded-only commits before fast-import.
# git fast-export --export-marks only writes commit marks (blobs are ignored per docs).
# This means incremental exports lose blob marks from source-marks. For excluded-only
# commits, fast-export can't reference parent blobs -> emits an orphan root commit
# instead of a proper child. Piping that to fast-import would fail with
# "new tip does not contain old tip". Detecting and skipping avoids this.
git fast-export --import-marks="$SOURCE_MARKS" --export-marks="$SOURCE_MARKS" -1 "$COMMIT_HASH" \
    ${PATHSPEC_ARGS:+-- "${PATHSPEC_ARGS[@]}"} \
    >"$EXPORT_OUT" 2>"$EXPORT_ERR"
EXPORT_RC=$?

if [ "$EXPORT_RC" -ne 0 ]; then
    _sync_log "$COMMIT_SHORT" ">>intermediary" "fast-export FAILED rc=$EXPORT_RC"
    [ -s "$EXPORT_ERR" ] && _sync_log "$COMMIT_SHORT" ">>intermediary" "export stderr: $(cat "$EXPORT_ERR")"
    echo -e "\033[1;31mclaude-cage:\033[0m Sync failed for commit $COMMIT_SHORT$SCOPE_LABEL (export=$EXPORT_RC)"
    rm -f "$EXPORT_ERR" "$EXPORT_OUT"
    exit 1
fi

# Rewrite hash-based refs to proper branch refs.
# git fast-export -1 <hash> uses the hash as the ref name (e.g. "commit <hash>")
# instead of "commit refs/heads/<branch>". fast-import needs a proper ref to
# update the branch pointer.
if [ -n "$current_branch" ]; then
    sed -i "s|^commit ${COMMIT_HASH}$|commit refs/heads/${current_branch}|;s|^reset ${COMMIT_HASH}$|reset refs/heads/${current_branch}|" "$EXPORT_OUT"
fi

# Strip scope prefix from fast-export paths (scoped intermediaries only).
# Uses the shared strip-prefix script installed in the intermediary.
if [ -n "$SCOPE_PATH" ]; then
    "$INTERMEDIARY/claude-cage-strip-prefix" "${SCOPE_PATH}/" "$EXPORT_OUT"
fi

# Excluded-only detection: no commit line means fast-export dropped it entirely (small repos).
if ! grep -q '^commit ' "$EXPORT_OUT"; then
    echo "0 $COMMIT_HASH" >> "$COMMIT_MAP"
    _sync_log "$COMMIT_SHORT" ">>intermediary" "excluded-only commit (no commit line), mapped to 0"
    echo -e "\033[1;31mclaude-cage:\033[0m Nothin' in scope$SCOPE_LABEL — commit only touches excluded or out-of-scope files"
    rm -f "$EXPORT_ERR" "$EXPORT_OUT"
    exit 0
fi

# No from line: either excluded-only (parent in marks, all changes filtered out)
# or marks gap (parent not in marks, e.g. from sync_to_source/git-am or prior
# excluded-only commit). Check parent to distinguish.
if ! grep -q '^from ' "$EXPORT_OUT"; then
    _PARENT=$(git rev-parse "${COMMIT_HASH}^" 2>/dev/null) || true
    _PARENT_MARKED=false
    if [ -n "$_PARENT" ] && [ -f "$SOURCE_MARKS" ] && grep -q " ${_PARENT}$" "$SOURCE_MARKS" 2>/dev/null; then
        _PARENT_MARKED=true
    fi
    if [ "$_PARENT_MARKED" = true ] || [ -z "$_PARENT" ]; then
        # Parent IS in marks (or root commit) but no from line -> truly excluded-only
        echo "0 $COMMIT_HASH" >> "$COMMIT_MAP"
        _sync_log "$COMMIT_SHORT" ">>intermediary" "excluded-only commit, mapped to 0"
        echo -e "\033[1;31mclaude-cage:\033[0m Nothin' in scope$SCOPE_LABEL — commit only touches excluded or out-of-scope files"
        rm -f "$EXPORT_ERR" "$EXPORT_OUT"
        exit 0
    fi
    # Parent NOT in marks — marks gap. Inject intermediary branch HEAD as parent.
    # The deleteall + full-tree reconstruction produces the correct tree state.
    _INT_HEAD=$(git -C "$INTERMEDIARY" rev-parse "$current_branch" 2>/dev/null)
    if [ -n "$_INT_HEAD" ]; then
        _sync_log "$COMMIT_SHORT" ">>intermediary" "marks gap: injecting parent ${_INT_HEAD:0:8}"
        awk -v parent="$_INT_HEAD" '/^(merge |deleteall$)/ && !done { print "from " parent; done=1 } { print }' \
            "$EXPORT_OUT" > "$EXPORT_OUT.fix" && mv "$EXPORT_OUT.fix" "$EXPORT_OUT"
    else
        echo "0 $COMMIT_HASH" >> "$COMMIT_MAP"
        _sync_log "$COMMIT_SHORT" ">>intermediary" "excluded-only (no intermediary HEAD for $current_branch)"
        echo -e "\033[1;31mclaude-cage:\033[0m Nothin' in scope$SCOPE_LABEL — commit only touches excluded or out-of-scope files"
        rm -f "$EXPORT_ERR" "$EXPORT_OUT"
        exit 0
    fi
fi

echo -e "\033[1;31mclaude-cage:\033[0m Updating intermediary$SCOPE_LABEL, run 'git pull' from claude-cage"

IMPORT_ERR=$(mktemp 2>/dev/null || echo "/tmp/claude-cage-import-err.$$")
git -C "$INTERMEDIARY" fast-import --import-marks="$IMPORT_MARKS" --export-marks="$IMPORT_MARKS" --quiet \
    <"$EXPORT_OUT" 2>"$IMPORT_ERR"
IMPORT_RC=$?

if [ "$IMPORT_RC" -ne 0 ]; then
    _sync_log "$COMMIT_SHORT" ">>intermediary" "fast-import FAILED rc=$IMPORT_RC"
    [ -s "$IMPORT_ERR" ] && _sync_log "$COMMIT_SHORT" ">>intermediary" "import stderr: $(cat "$IMPORT_ERR")"
    _IMPORT_MSG="Sync failed for commit $COMMIT_SHORT$SCOPE_LABEL (import=$IMPORT_RC)"
    [ -s "$IMPORT_ERR" ] && _IMPORT_MSG="$_IMPORT_MSG: $(cat "$IMPORT_ERR")"
    echo -e "\033[1;31mclaude-cage:\033[0m $_IMPORT_MSG"
    rm -f "$EXPORT_ERR" "$IMPORT_ERR" "$EXPORT_OUT"
    exit 1
fi
rm -f "$EXPORT_ERR" "$IMPORT_ERR" "$EXPORT_OUT"

# Update commit mapping from marks
if [ -f "$SOURCE_MARKS" ] && [ -f "$IMPORT_MARKS" ]; then
    awk 'NR==FNR { source[$1]=$2; next } { if ($1 in source) print $2, source[$1] }' \
        "$SOURCE_MARKS" "$IMPORT_MARKS" >> "$COMMIT_MAP"
fi

# If commit still not in mapping after marks join, record as excluded-only
if ! grep -q " ${COMMIT_HASH}$" "$COMMIT_MAP" 2>/dev/null; then
    echo "0 $COMMIT_HASH" >> "$COMMIT_MAP"
    _sync_log "$COMMIT_SHORT" ">>intermediary" "excluded-only commit, mapped to 0"
else
    _sync_log "$COMMIT_SHORT" ">>intermediary" "fast-import ok"
fi
SYNCEOF
    chmod +x "$intermediary_dir/claude-cage-sync-commit"
}

# Strip the scope prefix from fast-export stream paths in a temp file.
# Thin wrapper around the installed strip-prefix script.
# Arguments: $1 = file, $2 = prefix (e.g. "services/api/"), $3 = intermediary_dir
strip_scope_prefix() {
    local file="$1"
    local prefix="$2"
    local intermediary_dir="$3"
    "$intermediary_dir/claude-cage-strip-prefix" "$prefix" "$file"
}

# Build :(exclude,glob) pathspec args from pipe-delimited exclude patterns
# Patterns without / get **/ prepended for basename matching at any depth
# Patterns with / are used as-is for full path matching
# Each pattern also gets a /**-suffixed variant to match directory contents
# (git pathspec matches file paths, not directories, so **/__pycache__
# alone won't match __pycache__/module.pyc — the /** variant is needed)
# Arguments: $1 = pipe-delimited exclude patterns (e.g. ".env|*.log|secrets/")
# Output: one pathspec arg per line on stdout
build_exclude_pathspecs() {
    local cfg_exclude="$1"
    if [ -z "$cfg_exclude" ]; then
        return
    fi
    local -a patterns
    IFS='|' read -ra patterns <<< "$cfg_exclude"
    local pat pathspec
    for pat in "${patterns[@]}"; do
        if [[ "$pat" == */* ]]; then
            pathspec="$pat"
        else
            pathspec="**/$pat"
        fi
        printf '%s\n' ":(exclude,glob)$pathspec"
        # Add /** variant to match files inside matching directories
        # Strip trailing / or /* before appending /** to avoid double slashes
        local base="${pathspec%/}"
        base="${base%/\*}"
        printf '%s\n' ":(exclude,glob)${base}/**"
    done
}

# Compute a hash of exclude patterns for change detection
compute_exclude_hash() {
    local exclude_patterns="$1"
    if [ -z "$exclude_patterns" ]; then
        echo "empty"
    else
        echo -n "$exclude_patterns" | md5sum | cut -c1-32
    fi
}

# Build commit mapping from fast-export/fast-import marks files
# Joins source marks and import marks on mark ID to produce
# <intermediary-hash> <source-hash> lines
# Also detects dropped commits (in source rev-list but absent from source marks)
# and maps them to "0 <source-hash>"
# Arguments:
#   $1 - source_marks_path
#   $2 - import_marks_path
#   $3 - commit_map_path (output, append mode)
#   $4 - source_dir (for rev-list of dropped commits)
#   $5 - rev_range (e.g. "main~50..main feature/foo")
build_commit_map_from_marks() {
    local source_marks="$1"
    local import_marks="$2"
    local commit_map="$3"
    local source_dir="$4"
    local rev_range="$5"

    # Join marks on mark ID: source marks have :<id> <source-hash>,
    # import marks have :<id> <intermediary-hash>
    # Both files are in format: :<mark-id> <hash>
    if [ -f "$source_marks" ] && [ -f "$import_marks" ]; then
        # Use awk to join on mark ID
        awk '
        NR==FNR { source[$1] = $2; next }
        { if ($1 in source) print $2, source[$1] }
        ' "$source_marks" "$import_marks" >> "$commit_map"
    fi

    # Detect dropped commits (in source rev-list but not in source marks)
    if [ -n "$rev_range" ] && [ -n "$source_dir" ] && [ -f "$source_marks" ]; then
        # Get all commits in rev range
        local all_commits
        all_commits=$(git -C "$source_dir" rev-list $rev_range 2>/dev/null) || true

        # Get all source hashes from marks
        local -A marked_hashes
        while read -r _mark hash; do
            marked_hashes["$hash"]=1
        done < "$source_marks"

        # Commits in rev-list but not in marks were dropped (exclude-only commits)
        local commit
        for commit in $all_commits; do
            if [ -z "${marked_hashes[$commit]+_}" ]; then
                echo "0 $commit" >> "$commit_map"
            fi
        done
    fi
}

# Catch up all intermediary branches to match source
# Adds the current branch if missing, then incrementally fast-exports
# new commits for every branch in the intermediary.
# Arguments: $1 = source_dir, $2 = intermediary_dir
# Returns 0 if any branches were updated, 1 if all already in sync
catchup_intermediary_branches() {
    local source_dir="$1"
    local intermediary_dir="$2"

    local source_marks_path
    source_marks_path=$(get_source_marks_path "$intermediary_dir")
    local import_marks_path
    import_marks_path=$(get_import_marks_path "$intermediary_dir")
    local commit_map_path
    commit_map_path=$(get_commit_map_path "$intermediary_dir")

    # Read scope_path from metadata (empty for unscoped)
    local scope_path=""
    local scope_path_file
    scope_path_file=$(get_scope_path_file "$intermediary_dir")
    if [ -f "$scope_path_file" ]; then
        scope_path=$(cat "$scope_path_file")
    fi

    # When scoped, fast-export must run from git root (pathspecs are CWD-relative)
    local export_dir="$source_dir"
    if [ -n "$scope_path" ]; then
        export_dir=$(get_git_root "$source_dir")
    fi

    # Build combined pathspec args: scope include + exclude
    local -a pathspec_args=()
    [ -n "$scope_path" ] && pathspec_args+=("$scope_path/")
    if [ -n "$cfg_exclude" ]; then
        while IFS= read -r _ea; do
            pathspec_args+=("$_ea")
        done < <(build_exclude_pathspecs "$cfg_exclude")
    fi

    local any_updated=false

    # Check if current branch exists in intermediary
    local branch_name
    branch_name=$(get_source_branch "$source_dir")
    if [ -n "$branch_name" ] && ! git -C "$intermediary_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
        echo "  Addin' branch $branch_name to intermediary..."
        any_updated=true

        # Calculate range base from existing intermediary's oldest commit
        local existing_range_base
        existing_range_base=$(git -C "$intermediary_dir" rev-list --all --reverse 2>/dev/null | head -1)

        # Map back to source hash
        local source_range_base=""
        if [ -f "$commit_map_path" ]; then
            source_range_base=$(awk -v ih="$existing_range_base" '$1 == ih { print $2; exit }' "$commit_map_path")
        fi

        if [ -n "$source_range_base" ] && [ "$dry_run" != true ]; then
            local catchup_tmp
            catchup_tmp=$(mktemp)
            git -C "$export_dir" fast-export \
                --import-marks="$source_marks_path" \
                --export-marks="$source_marks_path" \
                "${source_range_base}..${branch_name}" \
                ${pathspec_args:+-- "${pathspec_args[@]}"} \
                >"$catchup_tmp" 2>/dev/null
            [ -n "$scope_path" ] && strip_scope_prefix "$catchup_tmp" "$scope_path/" "$intermediary_dir"
            git -C "$intermediary_dir" fast-import \
                --import-marks="$import_marks_path" \
                --export-marks="$import_marks_path" \
                --quiet <"$catchup_tmp" 2>/dev/null
            rm -f "$catchup_tmp"

            # Update commit map
            build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "${source_range_base}..${branch_name}"
        fi

        # If branch still not in intermediary (all unique commits out-of-scope),
        # create ref from merge-base mapping
        if ! git -C "$intermediary_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            local _mb_hash _int_hash=""
            _mb_hash=$(git -C "$source_dir" merge-base "$(get_default_branch "$source_dir")" "$branch_name" 2>/dev/null) || true
            if [ -n "$_mb_hash" ] && [ -f "$commit_map_path" ]; then
                _int_hash=$(awk -v sh="$_mb_hash" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path")
                # Walk back if merge-base maps to 0 or isn't mapped
                local _walker="$_mb_hash" _walk_max=50
                while [ -z "$_int_hash" ] && [ "$_walk_max" -gt 0 ]; do
                    _walker=$(git -C "$source_dir" rev-parse "${_walker}^" 2>/dev/null) || break
                    _int_hash=$(awk -v sh="$_walker" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path")
                    _walk_max=$((_walk_max - 1))
                done
            fi
            if [ -n "$_int_hash" ]; then
                git -C "$intermediary_dir" branch "$branch_name" "$_int_hash" 2>/dev/null || true
            fi
        fi
    fi

    # Catch up all intermediary branches to source
    local ib
    while IFS= read -r ib; do
        ib="${ib#  }"  # strip leading spaces from git branch output
        ib="${ib#\* }"  # strip active branch marker
        [ -z "$ib" ] && continue

        # Check if source has this branch
        if ! git -C "$source_dir" rev-parse --verify "$ib" >/dev/null 2>&1; then
            continue
        fi

        local source_head
        source_head=$(git -C "$source_dir" rev-parse "$ib" 2>/dev/null)
        local intermediary_head
        intermediary_head=$(git -C "$intermediary_dir" rev-parse "$ib" 2>/dev/null)

        # Check if intermediary branch HEAD already maps to source branch HEAD
        if [ -f "$commit_map_path" ]; then
            if grep -q "^${intermediary_head} ${source_head}$" "$commit_map_path" 2>/dev/null; then
                continue  # Already in sync
            fi
        fi

        echo "  Catching up branch $ib..."
        any_updated=true
        if [ "$dry_run" != true ]; then
            # Look up source hash corresponding to intermediary HEAD via commit map
            local mapped_source_base=""
            if [ -f "$commit_map_path" ]; then
                mapped_source_base=$(awk -v ih="$intermediary_head" '$1 == ih && $2 != "0" { print $2; exit }' "$commit_map_path")
            fi
            if [ -z "$mapped_source_base" ]; then
                continue  # Can't determine range base
            fi

            # Check if source branch is still a descendant of the mapped base
            if ! git -C "$export_dir" merge-base --is-ancestor "$mapped_source_base" "$ib" 2>/dev/null; then
                # Branch was recreated at a divergent point — delete and let the
                # "new branches" section below re-create it from scratch
                git -C "$intermediary_dir" branch -D "$ib" 2>/dev/null || true
                continue
            fi

            local catchup_tmp
            catchup_tmp=$(mktemp)
            git -C "$export_dir" fast-export \
                --import-marks="$source_marks_path" \
                --export-marks="$source_marks_path" \
                "${mapped_source_base}..${ib}" \
                ${pathspec_args:+-- "${pathspec_args[@]}"} \
                >"$catchup_tmp" 2>/dev/null
            [ -n "$scope_path" ] && strip_scope_prefix "$catchup_tmp" "$scope_path/" "$intermediary_dir"
            git -C "$intermediary_dir" fast-import \
                --import-marks="$import_marks_path" \
                --export-marks="$import_marks_path" \
                --quiet <"$catchup_tmp" 2>/dev/null || true
            rm -f "$catchup_tmp"

            build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "${mapped_source_base}..${ib}"

            # If branch still not caught up (commits already imported via another branch),
            # update the ref directly from the commit map
            local current_int_head
            current_int_head=$(git -C "$intermediary_dir" rev-parse "$ib" 2>/dev/null)
            if ! grep -q "^${current_int_head} ${source_head}$" "$commit_map_path" 2>/dev/null; then
                local expected_int_hash
                expected_int_hash=$(awk -v sh="$source_head" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path")
                if [ -n "$expected_int_hash" ]; then
                    git -C "$intermediary_dir" update-ref "refs/heads/$ib" "$expected_int_hash" 2>/dev/null || true
                fi
            fi
        fi
    done < <(git -C "$intermediary_dir" branch --list 2>/dev/null)

    # Discover source branches not yet in intermediary and create refs
    local _default_branch
    _default_branch=$(get_default_branch "$source_dir")
    local _sb
    while IFS= read -r _sb; do
        [ "$_sb" = "$branch_name" ] && continue  # Already handled above
        if git -C "$intermediary_dir" rev-parse --verify "$_sb" >/dev/null 2>&1; then
            continue  # Already in intermediary
        fi
        # Check if branch's merge-base is mapped in the commit map
        local _mb_hash _int_hash=""
        _mb_hash=$(git -C "$source_dir" merge-base "$_default_branch" "$_sb" 2>/dev/null) || continue
        if [ -f "$commit_map_path" ]; then
            _int_hash=$(awk -v sh="$_mb_hash" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path")
            local _walker="$_mb_hash" _walk_max=50
            while [ -z "$_int_hash" ] && [ "$_walk_max" -gt 0 ]; do
                _walker=$(git -C "$source_dir" rev-parse "${_walker}^" 2>/dev/null) || break
                _int_hash=$(awk -v sh="$_walker" '$2 == sh && $1 != "0" { print $1; exit }' "$commit_map_path")
                _walk_max=$((_walk_max - 1))
            done
        fi
        if [ -n "$_int_hash" ]; then
            # Try fast-export first; if all commits are out-of-scope, create ref from mapping
            if [ "$dry_run" != true ]; then
                local catchup_tmp
                catchup_tmp=$(mktemp)
                git -C "$export_dir" fast-export \
                    --import-marks="$source_marks_path" \
                    --export-marks="$source_marks_path" \
                    "${_mb_hash}..${_sb}" \
                    ${pathspec_args:+-- "${pathspec_args[@]}"} \
                    >"$catchup_tmp" 2>/dev/null || true
                if [ -s "$catchup_tmp" ]; then
                    [ -n "$scope_path" ] && strip_scope_prefix "$catchup_tmp" "$scope_path/" "$intermediary_dir"
                    git -C "$intermediary_dir" fast-import \
                        --import-marks="$import_marks_path" \
                        --export-marks="$import_marks_path" \
                        --quiet <"$catchup_tmp" 2>/dev/null || true
                    build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "${_mb_hash}..${_sb}"
                fi
                rm -f "$catchup_tmp"
            fi
            # If branch still not created (all commits out-of-scope), create from mapping
            if ! git -C "$intermediary_dir" rev-parse --verify "$_sb" >/dev/null 2>&1; then
                git -C "$intermediary_dir" branch "$_sb" "$_int_hash" 2>/dev/null || true
            fi
            any_updated=true
        fi
    done < <(git -C "$source_dir" for-each-ref --format='%(refname:short)' refs/heads/)

    # Update source branches file
    local source_branches_path
    source_branches_path=$(get_source_branches_path "$intermediary_dir")
    git -C "$source_dir" for-each-ref --format='%(refname:short)' refs/heads/ > "$source_branches_path"

    if [ "$any_updated" = true ]; then
        return 0
    else
        return 1
    fi
}

# Detect the default branch for a source repository
# Detection order:
# 1. cfg_git_defaultBranch if not "auto"
# 2. git symbolic-ref refs/remotes/origin/HEAD
# 3. Check for main then master branch existence
# 4. Last resort: current branch
# Arguments: $1 = source directory
get_default_branch() {
    local source_dir="$1"

    # 1. Config override
    if [ -n "${cfg_git_defaultBranch:-}" ] && [ "$cfg_git_defaultBranch" != "auto" ]; then
        echo "$cfg_git_defaultBranch"
        return
    fi

    # 2. Remote HEAD symref
    local remote_head
    remote_head=$(git -C "$source_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||')
    if [ -n "$remote_head" ]; then
        echo "$remote_head"
        return
    fi

    # 3. Check for main then master
    if git -C "$source_dir" rev-parse --verify main >/dev/null 2>&1; then
        echo "main"
        return
    fi
    if git -C "$source_dir" rev-parse --verify master >/dev/null 2>&1; then
        echo "master"
        return
    fi

    # 4. Current branch
    git -C "$source_dir" branch --show-current
}

# Get current branch from source project
# Returns empty string and exits 1 if not on a branch (detached HEAD or no commits)
get_source_branch() {
    local source_dir="$1"
    local branch
    branch=$(git -C "$source_dir" branch --show-current)

    if [ -z "$branch" ]; then
        # Try to get default branch name
        branch=$(git -C "$source_dir" config --get init.defaultBranch 2>/dev/null)
        if [ -z "$branch" ]; then
            # Check if main or master exists
            if git -C "$source_dir" rev-parse --verify main >/dev/null 2>&1; then
                branch="main"
            elif git -C "$source_dir" rev-parse --verify master >/dev/null 2>&1; then
                branch="master"
            fi
        fi
    fi

    echo "$branch"
}

# Create or update the bare intermediary and work directory
# Arguments: $1 = source directory (defaults to pwd), $2 = scope_path (optional, relative to git root)
create_intermediary_clone() {
    local source_dir="${1:-$(pwd)}"
    local scope_path="${2:-}"
    local intermediary_dir
    local work_dir
    intermediary_dir=$(get_scoped_intermediary_path "$source_dir" "$scope_path")
    work_dir=$(get_scoped_work_path "$source_dir" "$scope_path")

    # When scoped, fast-export must run from git root (pathspecs are CWD-relative)
    local export_dir="$source_dir"
    if [ -n "$scope_path" ]; then
        export_dir=$(get_git_root "$source_dir")
    fi

    # Capture source branch before we start
    local source_branch
    source_branch=$(get_source_branch "$source_dir")
    local branch_name="${source_branch}"

    # Detect default branch for history anchoring
    local default_branch
    default_branch=$(get_default_branch "$source_dir")
    local history_depth="${cfg_git_historyDepth:-50}"

    echo "Source branch: $source_branch"
    echo "Default branch: $default_branch"

    # Compute exclude hash for change detection
    local current_exclude_hash
    current_exclude_hash=$(compute_exclude_hash "$cfg_exclude")

    if [ -d "$intermediary_dir" ] && [ -f "$intermediary_dir/HEAD" ]; then
        # Existing intermediary - check exclude hash
        local stored_exclude_hash=""
        local exclude_hash_path
        exclude_hash_path=$(get_exclude_hash_path "$intermediary_dir")
        if [ -f "$exclude_hash_path" ]; then
            stored_exclude_hash=$(cat "$exclude_hash_path")
        fi

        if [ "$stored_exclude_hash" != "$current_exclude_hash" ]; then
            echo ""
            echo "Exclude patterns changed. Need to rebuild the intermediary."
            echo "  Cleanin' out the old intermediary..."
            run rm -rf "$intermediary_dir"
            # Fall through to create new
        fi
    fi

    if [ ! -d "$intermediary_dir" ]; then
        # Create new bare intermediary
        echo ""
        echo "Buildin' your intermediary now..."

        run mkdir -p "$(dirname "$intermediary_dir")"

        if [ "$dry_run" = true ]; then
            echo "[dry-run] git init --bare $intermediary_dir"
            echo "[dry-run] git fast-export ... | git fast-import ..."
        else
            git init --bare "$intermediary_dir" --quiet

            # Install strip-prefix script (needed before first fast-export for scoped)
            [ -n "$scope_path" ] && install_strip_prefix_script "$intermediary_dir"

            # Calculate export range with merge-base widening
            local range_base
            range_base=$(git -C "$source_dir" rev-parse "${default_branch}~${history_depth}" 2>/dev/null) || \
                range_base=$(git -C "$source_dir" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1)

            # Widen to include merge-base of current branch if needed
            if [ "$source_branch" != "$default_branch" ]; then
                local merge_base
                merge_base=$(git -C "$source_dir" merge-base "$default_branch" "$source_branch" 2>/dev/null) || true
                if [ -n "$merge_base" ]; then
                    if ! git -C "$source_dir" merge-base --is-ancestor "$range_base" "$merge_base" 2>/dev/null; then
                        # Merge base is older than our range - widen
                        range_base="$merge_base"
                    fi
                fi
            fi

            # Discover in-scope branches (merge-base falls within range)
            local -a export_branches=("$default_branch")
            if [ "$source_branch" != "$default_branch" ]; then
                export_branches+=("$source_branch")
            fi

            local branch
            while IFS= read -r branch; do
                [ "$branch" = "$default_branch" ] && continue
                [ "$branch" = "$source_branch" ] && continue
                local mb
                mb=$(git -C "$source_dir" merge-base "$default_branch" "$branch" 2>/dev/null) || continue
                if git -C "$source_dir" merge-base --is-ancestor "$range_base" "$mb" 2>/dev/null; then
                    export_branches+=("$branch")
                fi
            done < <(git -C "$source_dir" for-each-ref --format='%(refname:short)' refs/heads/)

            # Build rev range args
            # If range_base is a root commit, export full branches (no range prefix)
            # because root..HEAD is empty when HEAD == root
            local is_root_range=false
            if ! git -C "$source_dir" rev-parse --verify "${range_base}^" >/dev/null 2>&1; then
                is_root_range=true
            fi

            local -a range_args=()
            for b in "${export_branches[@]}"; do
                range_args+=("$b")
            done

            local source_marks_path
            source_marks_path=$(get_source_marks_path "$intermediary_dir")
            local import_marks_path
            import_marks_path=$(get_import_marks_path "$intermediary_dir")
            local commit_map_path
            commit_map_path=$(get_commit_map_path "$intermediary_dir")

            if [ "$verbose" = true ]; then
                if [ "$is_root_range" = true ]; then
                    echo -e "${_yellow}[run] git fast-export {${export_branches[*]}} | git fast-import${_reset}" >&2
                else
                    echo -e "${_yellow}[run] git fast-export ${range_base}..{${export_branches[*]}} | git fast-import${_reset}" >&2
                fi
            fi

            # Build combined pathspec args: scope include + exclude
            local -a pathspec_args=()
            [ -n "$scope_path" ] && pathspec_args+=("$scope_path/")
            if [ -n "$cfg_exclude" ]; then
                while IFS= read -r _ea; do
                    pathspec_args+=("$_ea")
                done < <(build_exclude_pathspecs "$cfg_exclude")
            fi

            # Build fast-export range arguments
            local -a export_range_args=()
            if [ "$is_root_range" = true ]; then
                # Root commit included: export full branches
                export_range_args=("${range_args[@]}")
            else
                # Normal range: range_base..first_branch + other branches
                export_range_args=("${range_base}..${range_args[0]}" "${range_args[@]:1}")
            fi

            local export_tmp
            export_tmp=$(mktemp)
            git -C "$export_dir" fast-export \
                --export-marks="$source_marks_path" \
                "${export_range_args[@]}" \
                ${pathspec_args:+-- "${pathspec_args[@]}"} \
                >"$export_tmp" 2>/dev/null
            [ -n "$scope_path" ] && strip_scope_prefix "$export_tmp" "$scope_path/" "$intermediary_dir"
            git -C "$intermediary_dir" fast-import \
                --export-marks="$import_marks_path" \
                --quiet <"$export_tmp" 2>/dev/null
            rm -f "$export_tmp"

            # Fix bare HEAD to point to default branch
            git -C "$intermediary_dir" symbolic-ref HEAD "refs/heads/$default_branch"

            # Build commit mapping rev range
            local rev_range
            if [ "$is_root_range" = true ]; then
                rev_range="${range_args[*]}"
            else
                rev_range="${range_base}..${range_args[0]}"
                for b in "${range_args[@]:1}"; do
                    rev_range="$rev_range $b"
                done
            fi
            : > "$commit_map_path"
            build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "$rev_range"

            # Store source branch names for pre-receive guard
            local source_branches_path
            source_branches_path=$(get_source_branches_path "$intermediary_dir")
            git -C "$source_dir" for-each-ref --format='%(refname:short)' refs/heads/ > "$source_branches_path"

            # Prevent force pushes
            git -C "$intermediary_dir" config receive.denyNonFastForwards true

            # Store exclude hash
            local exclude_hash_path
            exclude_hash_path=$(get_exclude_hash_path "$intermediary_dir")
            echo "$current_exclude_hash" > "$exclude_hash_path"

            # Store scope and git root metadata
            echo "$scope_path" > "$(get_scope_path_file "$intermediary_dir")"
            local git_root
            git_root=$(get_git_root "$source_dir")
            echo "$git_root" > "$(get_git_root_file "$intermediary_dir")"

            # Store exclude pathspecs for hook runtime use
            local exclude_pathspecs_file
            exclude_pathspecs_file=$(get_exclude_pathspecs_file "$intermediary_dir")
            : > "$exclude_pathspecs_file"
            if [ -n "$cfg_exclude" ]; then
                build_exclude_pathspecs "$cfg_exclude" > "$exclude_pathspecs_file"
            fi

            # Create empty sync.log so symlinks aren't broken before first sync
            touch "$intermediary_dir/sync.log"

            # Register in repos.list
            repos_list_add "$source_dir" "$scope_path"

            # Clean up any narrower scoped intermediaries now covered by this one
            cleanup_child_intermediaries "$source_dir" "$scope_path"
        fi

        echo ""
        echo "Intermediary's ready at: $intermediary_dir"
        local commit_count
        commit_count=$(git -C "$intermediary_dir" rev-list --all --count 2>/dev/null || echo "?")
        local branch_count
        branch_count=$(git -C "$intermediary_dir" branch --list 2>/dev/null | wc -l)
        echo "  $commit_count commits across $branch_count branch(es)"
    else
        # Existing intermediary - incremental updates
        echo ""
        echo "Intermediary exists, checkin' for updates..."

        catchup_intermediary_branches "$source_dir" "$intermediary_dir" || true
    fi

    # Install hooks on bare intermediary
    if [ "$dry_run" != true ]; then
        install_intermediary_hooks "$intermediary_dir"
    fi

    # Create/recreate work directory
    if [ -d "$work_dir" ]; then
        echo "  Cleanin' out the old workspace..."
        run rm -rf "$work_dir"
    fi

    echo ""
    echo "Settin' up your workspace..."
    if [ "$dry_run" = true ]; then
        echo "[dry-run] git clone $intermediary_dir $work_dir"
    else
        run_quiet git clone --quiet "$intermediary_dir" "$work_dir"

        # Checkout current branch if not default
        if [ "$branch_name" != "$(git -C "$intermediary_dir" symbolic-ref --short HEAD 2>/dev/null)" ]; then
            if git -C "$intermediary_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
                run_quiet git -C "$work_dir" checkout --quiet "$branch_name" 2>/dev/null
            fi
        fi
    fi

    # Update origin to use the path as it appears inside the cage
    # Bare intermediary is mounted at /run<intermediary_path>
    local mounted_intermediary="/run${intermediary_dir}"
    run_quiet git -C "$work_dir" remote set-url origin "$mounted_intermediary"

    # Configure push to auto-setup upstream tracking
    if ! run_quiet git -C "$work_dir" config push.autoSetupRemote true; then
        echo "Warning: Failed to set push.autoSetupRemote config"
    fi

    # Store scope_path in work dir for cleanup to find the correct intermediary
    if [ "$dry_run" != true ] && [ -d "$work_dir/.git" ]; then
        echo "$scope_path" > "$work_dir/.git/claude-cage-scope-path"
    fi

    # Record this session as the latest for the project
    if [ "$dry_run" != true ]; then
        write_latest_session "$intermediary_dir" "${CLAUDE_CAGE_SESSION:-}"
    fi

    echo ""
    echo "Workspace is good to go: $work_dir"
    echo "  Branch: $branch_name"

    # Show what files are in work (verbose only)
    if [ "$verbose" = true ] && [ "$dry_run" != true ]; then
        echo ""
        echo "Here's what we're workin' with:"
        local file_count
        file_count=$(cd "$work_dir" && find . -type f -not -path './.git/*' | wc -l)
        (cd "$work_dir" && find . -type f -not -path './.git/*' | head -20)
        if [ "$file_count" -gt 20 ]; then
            echo "  ... plus $((file_count - 20)) more where that came from"
        fi
    fi
}

# Install post-receive and pre-receive hooks on bare intermediary
# Arguments: $1 = intermediary_dir (bare repo path)
install_intermediary_hooks() {
    local intermediary_dir="$1"
    local hooks_dir="$intermediary_dir/hooks"

    # Path to pipe as seen from inside the sandbox
    local mounted_pipe_path="${CLAUDE_CAGE_MOUNTED_PIPE:-/tmp/claude-cage/pipe}"

    mkdir -p "$hooks_dir"

    # Post-receive hook: notify pipe listener of pushes
    cat > "$hooks_dir/post-receive" << EOF
#!/bin/bash
SYNC_LOG="\$(git rev-parse --git-dir 2>/dev/null)/sync.log"
while read oldrev newrev refname; do
    printf '[%s] %s %-14s %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\${newrev:0:8}" "post-recv" "refname=\$refname oldrev=\${oldrev:0:8} newrev=\${newrev:0:8}" >> "\$SYNC_LOG"
    if [ "\${CAGE_DEBUG:-}" = "1" ]; then
        echo "claude-cage post-receive: \$refname \$oldrev -> \$newrev" >&2
    fi
    if [ -p "$mounted_pipe_path" ]; then
        echo "\$refname \$newrev \$oldrev" > "$mounted_pipe_path"
    else
        echo "claude-cage runnin' in manual sync mode — to bring changes back to source, run: claude-cage git-merge" >&2
    fi
done
EOF
    chmod +x "$hooks_dir/post-receive"

    # Pre-receive hook: guard against out-of-scope branch name collisions
    local source_branches_path
    source_branches_path=$(get_source_branches_path "$intermediary_dir")
    cat > "$hooks_dir/pre-receive" << 'HOOKEOF'
#!/bin/bash
# Guard against creating branches that collide with out-of-scope source branches
SOURCE_BRANCHES_FILE="$(git rev-parse --git-dir 2>/dev/null)/claude-cage-source-branches"
while read oldrev newrev refname; do
    # Only check new branch creation (oldrev is all zeros)
    if [ "$oldrev" = "0000000000000000000000000000000000000000" ]; then
        branch_name="${refname#refs/heads/}"
        # Check if this branch already exists in intermediary (allow - normal push)
        if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            continue
        fi
        # Check if branch name exists in source but not in intermediary
        if [ -f "$SOURCE_BRANCHES_FILE" ] && grep -qx "$branch_name" "$SOURCE_BRANCHES_FILE"; then
            echo "Hold on. Branch '$branch_name' exists on source but is outside the cage's history scope." >&2
            echo "Use a different name, or start claude-cage on that branch directly." >&2
            exit 1
        fi
    fi
done
HOOKEOF
    chmod +x "$hooks_dir/pre-receive"

    # Install sync-commit helper script (called by post-commit and post-merge hooks)
    install_sync_commit_script "$intermediary_dir"
}

# Set up .caged/ directory with symlinks to cache directories
# Arguments: $1 = source directory, $2 = scope_path (optional)
setup_caged_symlinks() {
    local source_dir="$1"
    local scope_path="${2:-}"
    local git_root
    git_root=$(get_git_root "$source_dir")

    if [ -z "$git_root" ]; then
        echo "Can't find git root for .caged/ setup - skippin' it."
        return 1
    fi

    local caged_dir="$git_root/.caged"
    local session_id="${CLAUDE_CAGE_SESSION:-default}"

    # Target paths in cache
    local work_target
    work_target=$(get_scoped_work_path "$source_dir" "$scope_path")
    local intermediary_target
    intermediary_target=$(get_scoped_intermediary_path "$source_dir" "$scope_path")

    # Create .caged directory
    run mkdir -p "$caged_dir"

    # Create self-ignoring .gitignore if missing
    if [ ! -f "$caged_dir/.gitignore" ]; then
        if [ "$dry_run" = true ]; then
            echo "[dry-run] Creating $caged_dir/.gitignore"
        else
            printf '*\n!.gitignore\n' > "$caged_dir/.gitignore"
        fi
    fi

    # Create/update top-level intermediary symlink (shared bare repo)
    local intermediary_symlink="$caged_dir/intermediary"
    if [ "$dry_run" = true ]; then
        echo "[dry-run] ln -sf $intermediary_target $intermediary_symlink"
    else
        rm -f "$intermediary_symlink"
        ln -s "$intermediary_target" "$intermediary_symlink"
    fi

    # Create/update top-level sync.log symlink
    local sync_log_target="$intermediary_target/sync.log"
    local sync_log_symlink="$caged_dir/sync.log"
    if [ "$dry_run" = true ]; then
        echo "[dry-run] ln -sf $sync_log_target $sync_log_symlink"
    else
        rm -f "$sync_log_symlink"
        ln -s "$sync_log_target" "$sync_log_symlink"
    fi

    # Create session-specific directory with work symlink. The directory name
    # is the user-facing display label ("default" or "session.N"), not the
    # on-disk cache id, so .caged/sessions/ stays readable.
    local display_name
    display_name=$(display_session_name "$session_id")
    local session_dir="$caged_dir/sessions/$display_name"
    run mkdir -p "$session_dir"

    local work_symlink="$session_dir/work"
    if [ "$dry_run" = true ]; then
        echo "[dry-run] ln -sf $work_target $work_symlink"
    else
        rm -f "$work_symlink"
        ln -s "$work_target" "$work_symlink"
    fi

    # Session log symlink
    if [ -n "${CLAUDE_CAGE_SESSION_LOG:-}" ] && [ -f "$CLAUDE_CAGE_SESSION_LOG" ]; then
        local log_symlink="$session_dir/log"
        if [ "$dry_run" = true ]; then
            echo "[dry-run] ln -sf $CLAUDE_CAGE_SESSION_LOG $log_symlink"
        else
            rm -f "$log_symlink"
            ln -s "$CLAUDE_CAGE_SESSION_LOG" "$log_symlink"
        fi
    fi

    verbose_log "  Created .caged/ symlinks (session: $session_id)"
}
