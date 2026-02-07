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

# Current session ID for path construction (set by main.sh before calling get_work_path)
# Format: YYYYMMDDHHMMSS timestamp
CLAUDE_CAGE_SESSION=""

# Get the work directory path for a source directory
# Work dirs are per-session: sessions/<session_id>/work$source_dir
# Arguments: $1 = source directory
get_work_path() {
    local source_dir="$1"
    local session_id="${CLAUDE_CAGE_SESSION:-default}"
    echo "$CLAUDE_CAGE_CACHE/sessions/$session_id/work$source_dir"
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
    echo -n "$git_root" | md5sum | cut -c1-12
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

    [ -f "$repos_file" ] || return

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

    [ -f "$repos_file" ] || return

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
    [ -f "$repos_file" ] || return

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
                # Clean empty parent dirs up to scoped/ top-level
                local parent
                parent=$(dirname "$child_idir")
                while [ "$parent" != "$CLAUDE_CAGE_CACHE/scoped" ] && [ "$parent" != "$CLAUDE_CAGE_CACHE" ]; do
                    [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ] && rm -rf "$parent" || break
                    parent=$(dirname "$parent")
                done
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
        # Clean empty parent dirs up to scoped/ top-level
        local parent
        parent=$(dirname "$idir")
        while [ "$parent" != "$CLAUDE_CAGE_CACHE/scoped" ] && [ "$parent" != "$CLAUDE_CAGE_CACHE" ]; do
            [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ] && rm -rf "$parent" || break
            parent=$(dirname "$parent")
        done
        repos_list_remove "$source_dir" "$scope_path"
        echo "Cleaned up scoped intermediary: $scope_path (broader scope covers it now)"
    fi
}

# List all cached sessions for a source directory (newest first)
# Discovers sessions across all scopes in the same git root via repos.list.
# Output: one line per session: "<session_id> <branch> <source_dir> <scope>"
# (scope is empty for unscoped sessions — naturally handled by read -r)
list_cached_sessions() {
    local source_dir="$1"
    local -a source_dirs=("$source_dir")

    # Discover cross-scope source dirs via repos.list
    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null) || true
    if [ -n "$git_root" ]; then
        local repos_file
        repos_file=$(get_repos_list_path "$source_dir")
        if [ -f "$repos_file" ]; then
            while IFS= read -r scope; do
                local sd
                if [ -z "$scope" ]; then
                    sd="$git_root"
                else
                    sd="$git_root/$scope"
                fi
                # Avoid duplicating the primary source_dir
                local already=false
                local existing
                for existing in "${source_dirs[@]}"; do
                    [ "$existing" = "$sd" ] && already=true && break
                done
                [ "$already" = false ] && source_dirs+=("$sd")
            done < "$repos_file"
        fi
    fi

    # Scan sessions for all discovered source dirs
    if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        local session_id sd
        for session_dir in $(ls -1dr "$CLAUDE_CAGE_CACHE/sessions"/* 2>/dev/null); do
            [ -d "$session_dir" ] || continue
            session_id=$(basename "$session_dir")
            for sd in "${source_dirs[@]}"; do
                local work="$session_dir/work$sd"
                # Must have .git to be a real work dir (not just a parent of a scoped work dir)
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

# Check if a work directory has uncommitted changes
# Returns 0 if dirty, 1 if clean
is_work_dirty() {
    local work_dir="$1"
    [ -d "$work_dir/.git" ] || return 1
    # Check for uncommitted changes
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

# Find a reusable session for a source directory
# Discovers sessions across all scopes in the same git root via repos.list.
# Sets globals:
#   REUSE_SESSION_ID      - session ID (or empty)
#   REUSE_SESSION_STATE   - "active" | "clean" | "dirty" | "none"
#   REUSE_SESSION_BRANCH  - branch name of the session's work dir
#   REUSE_SESSION_SOURCE  - source_dir of the top-priority session
#   REUSE_SESSION_SCOPE   - scope of the top-priority session
#   REUSE_ACTIVE_SESSIONS - newline-separated list of "session_id branch source_dir scope" for active sessions
#   REUSE_CLEAN_SESSIONS  - newline-separated list of "session_id branch source_dir scope" for inactive clean sessions
#   REUSE_DIRTY_SESSIONS  - newline-separated list of "session_id branch dirty_type source_dir scope" for inactive dirty sessions
find_reusable_session() {
    local source_dir="$1"

    REUSE_SESSION_ID=""
    REUSE_SESSION_STATE="none"
    REUSE_SESSION_BRANCH=""
    REUSE_SESSION_SOURCE=""
    REUSE_SESSION_SCOPE=""
    REUSE_ACTIVE_SESSIONS=""
    REUSE_DIRTY_SESSIONS=""
    REUSE_CLEAN_SESSIONS=""

    if [ ! -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        return
    fi

    # Build list of source_dirs to scan (cross-scope discovery)
    local -a source_dirs=("$source_dir")
    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null) || true
    if [ -n "$git_root" ]; then
        local repos_file
        repos_file=$(get_repos_list_path "$source_dir")
        if [ -f "$repos_file" ]; then
            while IFS= read -r _scope; do
                local _sd
                if [ -z "$_scope" ]; then
                    _sd="$git_root"
                else
                    _sd="$git_root/$_scope"
                fi
                local _already=false _existing
                for _existing in "${source_dirs[@]}"; do
                    [ "$_existing" = "$_sd" ] && _already=true && break
                done
                [ "$_already" = false ] && source_dirs+=("$_sd")
            done < "$repos_file"
        fi
    fi

    local -a active_sessions=()
    local -a inactive_clean=()
    local -a inactive_dirty=()

    # Scan sessions newest first, across all source_dirs
    local session_id session_dir sd work branch scope
    for session_dir in $(ls -1dr "$CLAUDE_CAGE_CACHE/sessions"/* 2>/dev/null); do
        [ -d "$session_dir" ] || continue
        session_id=$(basename "$session_dir")
        for sd in "${source_dirs[@]}"; do
            work="$session_dir/work$sd"
            # Must have .git to be a real work dir (not just a parent of a scoped work dir)
            [ -d "$work/.git" ] || continue

            branch=$(get_work_branch "$work")
            scope=""
            [ -f "$work/.git/claude-cage-scope-path" ] && \
                scope=$(cat "$work/.git/claude-cage-scope-path")

            # Check if session has a live PID (using correct source_dir for this work dir)
            if session_is_active "$sd" "$session_id"; then
                active_sessions+=("$session_id $branch $sd $scope")
            else
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
                if [ -n "$dirty_type" ]; then
                    inactive_dirty+=("$session_id $branch $dirty_type $sd $scope")
                else
                    inactive_clean+=("$session_id $branch $sd $scope")
                fi
            fi
        done
    done

    # Build active sessions list
    if [ ${#active_sessions[@]} -gt 0 ]; then
        REUSE_ACTIVE_SESSIONS=$(printf '%s\n' "${active_sessions[@]}")
    fi

    # Build dirty sessions list
    if [ ${#inactive_dirty[@]} -gt 0 ]; then
        REUSE_DIRTY_SESSIONS=$(printf '%s\n' "${inactive_dirty[@]}")
    fi

    # Build clean sessions list
    if [ ${#inactive_clean[@]} -gt 0 ]; then
        REUSE_CLEAN_SESSIONS=$(printf '%s\n' "${inactive_clean[@]}")
    fi

    # Priority: active > inactive dirty > inactive clean
    if [ ${#active_sessions[@]} -gt 0 ]; then
        read -r REUSE_SESSION_ID REUSE_SESSION_BRANCH REUSE_SESSION_SOURCE REUSE_SESSION_SCOPE \
            <<< "${active_sessions[0]}"
        REUSE_SESSION_STATE="active"
    elif [ ${#inactive_dirty[@]} -gt 0 ]; then
        local _dtype
        read -r REUSE_SESSION_ID REUSE_SESSION_BRANCH _dtype REUSE_SESSION_SOURCE REUSE_SESSION_SCOPE \
            <<< "${inactive_dirty[0]}"
        REUSE_SESSION_STATE="dirty"
    elif [ ${#inactive_clean[@]} -gt 0 ]; then
        read -r REUSE_SESSION_ID REUSE_SESSION_BRANCH REUSE_SESSION_SOURCE REUSE_SESSION_SCOPE \
            <<< "${inactive_clean[0]}"
        REUSE_SESSION_STATE="clean"
    fi
}

# Reuse an inactive clean session or create a new one
# Only reuses sessions matching the current source_dir (same-scope only).
# Arguments: $1 = source_dir
# Uses globals: REUSE_CLEAN_SESSIONS, CLAUDE_CAGE_CACHE
# Sets: CLAUDE_CAGE_SESSION
reuse_or_create_session() {
    local source_dir="$1"
    if [ -n "${REUSE_CLEAN_SESSIONS:-}" ]; then
        # Filter to same-source entries only (skip cross-scope clean sessions)
        local same_source csid cbranch csource cscope
        same_source=$(while IFS=' ' read -r csid cbranch csource cscope; do
            [ "$csource" = "$source_dir" ] && echo "$csid $cbranch $csource $cscope"
        done <<< "$REUSE_CLEAN_SESSIONS")
        if [ -n "$same_source" ]; then
            CLAUDE_CAGE_SESSION=$(echo "$same_source" | head -1 | awk '{print $1}')
            echo "Reusin' clean session $CLAUDE_CAGE_SESSION."
            return
        fi
    fi
    CLAUDE_CAGE_SESSION=$(date +%Y%m%d%H%M%S)
    if [ -d "$CLAUDE_CAGE_CACHE/sessions/$CLAUDE_CAGE_SESSION/work$source_dir" ]; then
        sleep 1
        CLAUDE_CAGE_SESSION=$(date +%Y%m%d%H%M%S)
    fi
}

# Clean up inactive clean sessions we're not using
# Only cleans sessions matching the current source_dir (same-scope only).
# Removes work dirs and empty parent/session dirs for all inactive clean
# sessions except the one currently selected (CLAUDE_CAGE_SESSION).
# Arguments: $1 = source_dir
# Uses globals: REUSE_CLEAN_SESSIONS, CLAUDE_CAGE_SESSION, CLAUDE_CAGE_CACHE
cleanup_stale_sessions() {
    local source_dir="$1"
    [ -z "${REUSE_CLEAN_SESSIONS:-}" ] && return
    [ "${dry_run:-}" = true ] && return

    local count=0
    local csid cbranch csource cscope
    while IFS=' ' read -r csid cbranch csource cscope; do
        [ -z "$csid" ] && continue
        [ "$csid" = "$CLAUDE_CAGE_SESSION" ] && continue
        [ "$csource" != "$source_dir" ] && continue  # Skip cross-scope

        local session_cache="$CLAUDE_CAGE_CACHE/sessions/$csid"
        local work_dir="$session_cache/work$source_dir"
        [ -d "$work_dir" ] || continue

        rm -rf "$work_dir"
        ((count++))

        # Remove .caged symlink for this session
        local caged_link="$source_dir/.caged/sessions/$csid"
        [ -d "$caged_link" ] && rm -rf "$caged_link"

        # Clean empty parent dirs up to session_cache/work
        local parent_dir
        parent_dir=$(dirname "$work_dir")
        while [ "$parent_dir" != "$session_cache/work" ] && [ "$parent_dir" != "$session_cache" ]; do
            [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir" 2>/dev/null)" ] && rm -rf "$parent_dir" || break
            parent_dir=$(dirname "$parent_dir")
        done

        # Clean empty session dir
        if [ -d "$session_cache/work" ] && [ -z "$(ls -A "$session_cache/work" 2>/dev/null)" ]; then
            rm -rf "$session_cache/work"
        fi
        if [ -d "$session_cache" ] && [ -z "$(ls -A "$session_cache" 2>/dev/null)" ]; then
            rm -rf "$session_cache"
        fi
    done <<< "$REUSE_CLEAN_SESSIONS"

    if [ "$count" -gt 0 ]; then
        echo "Cleaned up $count stale session(s)."
    fi
}

# Check if a specific session has a live PID for a project
# Arguments: $1 = source_dir, $2 = session_id
session_is_active() {
    local source_dir="$1"
    local session_id="$2"
    local path_hash
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
    local session_dir="$CLAUDE_CAGE_RUNTIME/sessions/$path_hash"

    [ -d "$session_dir" ] || return 1

    for pidfile in "$session_dir"/*; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(basename "$pidfile")
        # Read session ID from file content
        local file_session
        file_session=$(cat "$pidfile" 2>/dev/null)
        if [ "$file_session" = "$session_id" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# Clean up cache for a specific session
# Arguments: $1 = source directory, $2 = session_id (timestamp)
clean_session_cache() {
    local source_dir="$1"
    local session_id="$2"
    local session_cache="$CLAUDE_CAGE_CACHE/sessions/$session_id"
    local work_dir="$session_cache/work$source_dir"
    # Read scope from work dir metadata (if present) to find the correct intermediary
    local _clean_scope=""
    if [ -f "$work_dir/.git/claude-cage-scope-path" ]; then
        _clean_scope=$(cat "$work_dir/.git/claude-cage-scope-path")
    fi

    local intermediary_dir
    intermediary_dir=$(get_scoped_intermediary_path "$source_dir" "$_clean_scope")
    local caged_link="$source_dir/.caged/sessions/$session_id"

    # Remove source hooks for this project (only if no other sessions active)
    local git_root
    git_root=$(get_git_root "$source_dir" 2>/dev/null)
    if [ -n "$git_root" ]; then
        local path_hash
        path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
        local post_commit_hook="$git_root/.git/hooks/post-commit.d/claude-cage-$path_hash"

        if [ -f "$post_commit_hook" ] && ! has_other_sessions "$source_dir"; then
            run rm -f "$post_commit_hook"
            echo "Removed post-commit hook: $post_commit_hook"
            maybe_remove_dispatcher "$git_root" "post-commit"
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

    # Clean up empty parent directories between work_dir and session_cache/work
    local parent_dir
    parent_dir=$(dirname "$work_dir")
    while [ "$parent_dir" != "$session_cache/work" ] && [ "$parent_dir" != "$session_cache" ]; do
        [ -d "$parent_dir" ] && [ -z "$(ls -A "$parent_dir" 2>/dev/null)" ] && run rm -rf "$parent_dir" || break
        parent_dir=$(dirname "$parent_dir")
    done

    # Clean up empty session directory if no other projects use it
    if [ -d "$session_cache/work" ] && [ -z "$(ls -A "$session_cache/work" 2>/dev/null)" ]; then
        run rm -rf "$session_cache/work"
    fi
    if [ -d "$session_cache" ] && [ -z "$(ls -A "$session_cache" 2>/dev/null)" ]; then
        run rm -rf "$session_cache"
        echo "Removed empty session cache: $session_cache"
    fi

    # Check if shared intermediary should be removed
    # Only remove if no other sessions use it (no work dirs reference this source)
    local other_sessions_exist=false
    if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        for sd in "$CLAUDE_CAGE_CACHE/sessions"/*; do
            [ -d "$sd" ] || continue
            if [ -d "$sd/work$source_dir/.git" ]; then
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
        local parent
        parent=$(dirname "$intermediary_dir")
        while [ "$parent" != "$CLAUDE_CAGE_CACHE/intermediary" ] && [ "$parent" != "$CLAUDE_CAGE_CACHE/scoped" ] && [ "$parent" != "$CLAUDE_CAGE_CACHE" ]; do
            [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ] && run rm -rf "$parent" || break
            parent=$(dirname "$parent")
        done
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

        # Check if source is ahead (source HEAD not mapped)
        if [ -f "$commit_map_path" ]; then
            if grep -q " ${source_head}$" "$commit_map_path" 2>/dev/null; then
                continue  # Already in sync
            fi
            # Also check if intermediary head maps to source head
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
    work_dir=$(get_work_path "$source_dir")

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
    echo "\$refname \$newrev \$oldrev" > "$mounted_pipe_path"
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
    work_target=$(get_work_path "$source_dir")
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

    # Create session-specific directory with work symlink
    local session_dir="$caged_dir/sessions/$session_id"
    run mkdir -p "$session_dir"

    local work_symlink="$session_dir/work"
    if [ "$dry_run" = true ]; then
        echo "[dry-run] ln -sf $work_target $work_symlink"
    else
        rm -f "$work_symlink"
        ln -s "$work_target" "$work_symlink"
    fi

    if [ "$verbose" = true ]; then
        echo "  Created .caged/ symlinks (session: $session_id)"
    fi
}
