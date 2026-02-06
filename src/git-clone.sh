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

# List all cached sessions for a source directory (newest first)
# Output: one line per session: "<session_id> <branch>"
list_cached_sessions() {
    local source_dir="$1"

    # Check each session directory in cache (work dirs are per-session)
    if [ -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        # List sessions newest first (reverse sort on timestamp dirs)
        local session_id
        for session_dir in $(ls -1dr "$CLAUDE_CAGE_CACHE/sessions"/* 2>/dev/null); do
            [ -d "$session_dir" ] || continue
            session_id=$(basename "$session_dir")
            # Check if this session has a work directory for our source
            local work="$session_dir/work$source_dir"
            if [ -d "$work" ]; then
                local branch
                branch=$(get_work_branch "$work")
                echo "$session_id $branch"
            fi
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
# Sets globals:
#   REUSE_SESSION_ID      - session ID (or empty)
#   REUSE_SESSION_STATE   - "active" | "clean" | "dirty" | "none"
#   REUSE_SESSION_BRANCH  - branch name of the session's work dir
#   REUSE_ACTIVE_SESSIONS - newline-separated list of "session_id branch" for active sessions
find_reusable_session() {
    local source_dir="$1"

    REUSE_SESSION_ID=""
    REUSE_SESSION_STATE="none"
    REUSE_SESSION_BRANCH=""
    REUSE_ACTIVE_SESSIONS=""
    REUSE_DIRTY_SESSIONS=""

    if [ ! -d "$CLAUDE_CAGE_CACHE/sessions" ]; then
        return
    fi

    local -a active_sessions=()
    local -a inactive_clean=()
    local -a inactive_dirty=()

    # Scan sessions newest first
    local session_id session_dir work branch
    for session_dir in $(ls -1dr "$CLAUDE_CAGE_CACHE/sessions"/* 2>/dev/null); do
        [ -d "$session_dir" ] || continue
        session_id=$(basename "$session_dir")
        work="$session_dir/work$source_dir"
        [ -d "$work" ] || continue

        branch=$(get_work_branch "$work")

        # Check if session has a live PID
        if session_is_active "$source_dir" "$session_id"; then
            active_sessions+=("$session_id $branch")
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
                inactive_dirty+=("$session_id $branch $dirty_type")
            else
                inactive_clean+=("$session_id $branch")
            fi
        fi
    done

    # Build active sessions list
    if [ ${#active_sessions[@]} -gt 0 ]; then
        REUSE_ACTIVE_SESSIONS=$(printf '%s\n' "${active_sessions[@]}")
    fi

    # Build dirty sessions list
    if [ ${#inactive_dirty[@]} -gt 0 ]; then
        REUSE_DIRTY_SESSIONS=$(printf '%s\n' "${inactive_dirty[@]}")
    fi

    # Priority: active > inactive dirty > inactive clean
    if [ ${#active_sessions[@]} -gt 0 ]; then
        REUSE_SESSION_ID="${active_sessions[0]%% *}"
        REUSE_SESSION_BRANCH="${active_sessions[0]#* }"
        REUSE_SESSION_STATE="active"
    elif [ ${#inactive_dirty[@]} -gt 0 ]; then
        REUSE_SESSION_ID="${inactive_dirty[0]%% *}"
        REUSE_SESSION_BRANCH="${inactive_dirty[0]#* }"
        REUSE_SESSION_STATE="dirty"
    elif [ ${#inactive_clean[@]} -gt 0 ]; then
        REUSE_SESSION_ID="${inactive_clean[0]%% *}"
        REUSE_SESSION_BRANCH="${inactive_clean[0]#* }"
        REUSE_SESSION_STATE="clean"
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
    local intermediary_dir
    intermediary_dir=$(get_intermediary_path "$source_dir")
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
            if [ -d "$sd/work$source_dir" ]; then
                other_sessions_exist=true
                break
            fi
        done
    fi

    if [ "$other_sessions_exist" = false ] && [ -d "$intermediary_dir" ]; then
        run rm -rf "$intermediary_dir"
        echo "Removed shared intermediary: $intermediary_dir"
        # Clean up empty parent dirs
        local parent
        parent=$(dirname "$intermediary_dir")
        while [ "$parent" != "$CLAUDE_CAGE_CACHE/intermediary" ] && [ "$parent" != "$CLAUDE_CAGE_CACHE" ]; do
            [ -d "$parent" ] && [ -z "$(ls -A "$parent" 2>/dev/null)" ] && run rm -rf "$parent" || break
            parent=$(dirname "$parent")
        done
    fi

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
# Arguments: $1 = source directory (defaults to pwd)
create_intermediary_clone() {
    local source_dir="${1:-$(pwd)}"
    local intermediary_dir
    local work_dir
    intermediary_dir=$(get_intermediary_path "$source_dir")
    work_dir=$(get_work_path "$source_dir")

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

    if [ -d "$intermediary_dir" ]; then
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

            # Build :(exclude,glob) pathspec args for fast-export
            local -a exclude_args=()
            if [ -n "$cfg_exclude" ]; then
                while IFS= read -r _ea; do
                    exclude_args+=("$_ea")
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

            git -C "$source_dir" fast-export \
                --export-marks="$source_marks_path" \
                "${export_range_args[@]}" \
                ${exclude_args:+-- "${exclude_args[@]}"} \
                2>/dev/null \
                | git -C "$intermediary_dir" fast-import \
                    --export-marks="$import_marks_path" \
                    --quiet 2>/dev/null

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

            # Create empty sync.log so symlinks aren't broken before first sync
            touch "$intermediary_dir/sync.log"
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

        local source_marks_path
        source_marks_path=$(get_source_marks_path "$intermediary_dir")
        local import_marks_path
        import_marks_path=$(get_import_marks_path "$intermediary_dir")
        local commit_map_path
        commit_map_path=$(get_commit_map_path "$intermediary_dir")

        # Check if current branch exists in intermediary
        if ! git -C "$intermediary_dir" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            echo "  Addin' branch $branch_name to intermediary..."

            # Calculate range base from existing intermediary's oldest commit
            local existing_range_base
            existing_range_base=$(git -C "$intermediary_dir" rev-list --all --reverse 2>/dev/null | head -1)

            # Map back to source hash
            local source_range_base=""
            if [ -f "$commit_map_path" ]; then
                source_range_base=$(awk -v ih="$existing_range_base" '$1 == ih { print $2; exit }' "$commit_map_path")
            fi

            if [ -n "$source_range_base" ] && [ "$dry_run" != true ]; then
                local -a exclude_args=()
                if [ -n "$cfg_exclude" ]; then
                    while IFS= read -r _ea; do
                        exclude_args+=("$_ea")
                    done < <(build_exclude_pathspecs "$cfg_exclude")
                fi
                git -C "$source_dir" fast-export \
                    --import-marks="$source_marks_path" \
                    --export-marks="$source_marks_path" \
                    "${source_range_base}..${branch_name}" \
                    ${exclude_args:+-- "${exclude_args[@]}"} \
                    2>/dev/null \
                    | git -C "$intermediary_dir" fast-import \
                        --import-marks="$import_marks_path" \
                        --export-marks="$import_marks_path" \
                        --quiet 2>/dev/null

                # Update commit map
                build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "${source_range_base}..${branch_name}"
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
            if [ "$dry_run" != true ]; then
                local -a exclude_args=()
                if [ -n "$cfg_exclude" ]; then
                    while IFS= read -r _ea; do
                        exclude_args+=("$_ea")
                    done < <(build_exclude_pathspecs "$cfg_exclude")
                fi
                git -C "$source_dir" fast-export \
                    --import-marks="$source_marks_path" \
                    --export-marks="$source_marks_path" \
                    "${intermediary_head}..${ib}" \
                    ${exclude_args:+-- "${exclude_args[@]}"} \
                    2>/dev/null \
                    | git -C "$intermediary_dir" fast-import \
                        --import-marks="$import_marks_path" \
                        --export-marks="$import_marks_path" \
                        --quiet 2>/dev/null || true

                build_commit_map_from_marks "$source_marks_path" "$import_marks_path" "$commit_map_path" "$source_dir" "${intermediary_head}..${ib}"
            fi
        done < <(git -C "$intermediary_dir" branch --list 2>/dev/null)

        # Update source branches file
        local source_branches_path
        source_branches_path=$(get_source_branches_path "$intermediary_dir")
        git -C "$source_dir" for-each-ref --format='%(refname:short)' refs/heads/ > "$source_branches_path"
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
    local mounted_intermediary="/run$(get_intermediary_path "$source_dir")"
    run_quiet git -C "$work_dir" remote set-url origin "$mounted_intermediary"

    # Configure push to auto-setup upstream tracking
    if ! run_quiet git -C "$work_dir" config push.autoSetupRemote true; then
        echo "Warning: Failed to set push.autoSetupRemote config"
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
# Arguments: $1 = source directory
setup_caged_symlinks() {
    local source_dir="$1"
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
    intermediary_target=$(get_intermediary_path "$source_dir")

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
