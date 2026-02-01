# ============================================================================
# Git archive + fresh init (no history of excluded files)
# ============================================================================

# Verify and fix the work directory's origin URL
# The origin should point to /run<source_dir> for the bwrap/docker mount
# Arguments:
#   $1 - work_dir: The work directory
#   $2 - source_dir: The original source directory path
verify_work_origin() {
    local work_dir="$1"
    local source_dir="$2"
    local expected_origin="/run$source_dir"

    [ ! -d "$work_dir/.git" ] && return 0

    local current_origin
    current_origin=$(git -C "$work_dir" remote get-url origin 2>/dev/null || echo "")

    if [ "$current_origin" != "$expected_origin" ]; then
        echo "Fixin' up the git origin (was: $current_origin)"
        git -C "$work_dir" remote set-url origin "$expected_origin"
        echo "  Now pointin' at: $expected_origin"
    fi
}

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

# Current branch for path construction (set by main.sh before calling get_cage_path)
CLAUDE_CAGE_BRANCH=""

# Get the cache path for a source directory
# Arguments: $1 = source directory, $2 = type (work|intermediary)
# Uses CLAUDE_CAGE_BRANCH if set, otherwise defaults to "default"
get_cage_path() {
    local source_dir="$1"
    local type="$2"
    local branch_dir="${CLAUDE_CAGE_BRANCH:-default}"
    branch_dir=$(sanitize_branch_name "$branch_dir")
    echo "$CLAUDE_CAGE_CACHE/branches/$branch_dir/$type$source_dir"
}

# Get the pipe path for a source directory
# Uses CLAUDE_CAGE_BRANCH if set
get_pipe_path() {
    local source_dir="$1"
    local branch_dir="${CLAUDE_CAGE_BRANCH:-default}"
    branch_dir=$(sanitize_branch_name "$branch_dir")
    echo "$CLAUDE_CAGE_RUNTIME/pipes/$branch_dir$source_dir"
}

# Get the state file path for a source directory
# State file tracks the last processed commit from source
# Uses CLAUDE_CAGE_BRANCH if set, hashes the path for a flat file structure
get_state_path() {
    local source_dir="$1"
    local branch_dir="${CLAUDE_CAGE_BRANCH:-default}"
    branch_dir=$(sanitize_branch_name "$branch_dir")
    local path_hash
    path_hash=$(echo -n "$source_dir" | md5sum | cut -c1-12)
    echo "$CLAUDE_CAGE_CACHE/branches/$branch_dir/state-$path_hash"
}

# Get the branch work root directory (contains all projects for a branch)
# This is mounted at / so all same-branch projects are visible at original paths
get_branch_work_root() {
    local branch_dir="${CLAUDE_CAGE_BRANCH:-default}"
    branch_dir=$(sanitize_branch_name "$branch_dir")
    echo "$CLAUDE_CAGE_CACHE/branches/$branch_dir/work"
}

# Get the branch intermediary root directory (contains all intermediaries for a branch)
# This is mounted at /run so all same-branch intermediaries are accessible
get_branch_intermediary_root() {
    local branch_dir="${CLAUDE_CAGE_BRANCH:-default}"
    branch_dir=$(sanitize_branch_name "$branch_dir")
    echo "$CLAUDE_CAGE_CACHE/branches/$branch_dir/intermediary"
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

# Create the intermediary and work directories
# Arguments: $1 = source directory (defaults to pwd)
create_intermediary_clone() {
    local source_dir="${1:-$(pwd)}"
    local intermediary_dir
    local work_dir
    intermediary_dir=$(get_cage_path "$source_dir" "intermediary")
    work_dir=$(get_cage_path "$source_dir" "work")

    # Capture source branch before we start
    local source_branch
    source_branch=$(get_source_branch "$source_dir")
    echo "Source branch: $source_branch"

    echo ""
    echo "Buildin' your intermediary now..."

    # Clean up existing directories if they exist
    if [ -d "$intermediary_dir" ]; then
        echo "  Cleanin' out the old intermediary..."
        run rm -rf "$intermediary_dir"
    fi
    if [ -d "$work_dir" ]; then
        echo "  Cleanin' out the old workspace..."
        run rm -rf "$work_dir"
    fi

    run mkdir -p "$intermediary_dir"

    # Build tar exclude flags (--exclude=pattern)
    local -a tar_excludes=()
    if [ -n "$cfg_exclude" ]; then
        IFS='|' read -ra excludes <<< "$cfg_exclude"
        for pattern in "${excludes[@]}"; do
            # Convert gitignore-style ** to tar glob
            # Remove leading **/ for tar compatibility
            local tar_pattern="${pattern#\*\*/}"
            tar_excludes+=("--exclude=$tar_pattern")
        done
    fi

    # Extract files using git ls-files + tar (ignores .gitattributes export-ignore)
    echo "  Pullin' out the good stuff..."
    if [ -n "$cfg_exclude" ]; then
        IFS='|' read -ra excludes <<< "$cfg_exclude"
        for pattern in "${excludes[@]}"; do
            echo "    Exclude: $pattern"
        done
    fi

    if [ "$dry_run" = true ]; then
        echo "[dry-run] git -C $source_dir ls-files -z | tar -C $source_dir --null -T - -cf - | tar -x ${tar_excludes[*]} -C $intermediary_dir"
    else
        if [ "$verbose" = true ]; then
            echo -e "${_yellow}[run] git -C $source_dir ls-files -z | tar -C $source_dir --null -T - -cf - | tar -x ${tar_excludes[*]} -C $intermediary_dir${_reset}" >&2
        fi
        git -C "$source_dir" ls-files -z | tar -C "$source_dir" --null -T - -cf - | tar -x "${tar_excludes[@]}" -C "$intermediary_dir"
    fi

    # Initialize fresh git repo (no history of excluded files)
    echo "  Startin' fresh, clean slate..."
    run git -C "$intermediary_dir" init
    run git -C "$intermediary_dir" add .
    if [ "$dry_run" = true ]; then
        echo "[dry-run] git -C $intermediary_dir commit -m 'Initial commit from claude-cage'"
    else
        if [ "$verbose" = true ]; then
            echo -e "${_yellow}[run] git -C $intermediary_dir commit -m 'Initial commit from claude-cage'${_reset}" >&2
        fi
        git -C "$intermediary_dir" commit -m "Initial commit from claude-cage" >/dev/null
    fi

    echo ""
    echo "Intermediary's ready at: $intermediary_dir"

    # Create claude branch in intermediary (this is where source commits land)
    echo "  Settin' up the claude branch..."
    run git -C "$intermediary_dir" checkout -b "claude"

    # Allow pushing to checked-out branch (updates working tree automatically)
    run git -C "$intermediary_dir" config receive.denyCurrentBranch updateInstead

    # Create work directory by cloning from intermediary
    echo ""
    echo "Settin' up your workspace..."
    run git clone "$intermediary_dir" "$work_dir"

    # Update origin to use the path as it appears inside the cage
    # Intermediary is mounted at /run, so origin is /run<source_dir>
    echo "  Setting origin to cage path: /run$source_dir"
    run git -C "$work_dir" remote set-url origin "/run$source_dir"

    # Configure push to auto-setup upstream tracking
    run git -C "$work_dir" config push.autoSetupRemote true

    echo ""
    echo "Workspace is good to go: $work_dir"
    echo "  Branch: claude"

    # Show what files are in work (skip in dry-run)
    if [ "$dry_run" != true ]; then
        echo ""
        echo "Here's what we're workin' with:"
        local file_count
        file_count=$(cd "$work_dir" && find . -type f -not -path './.git/*' | wc -l)
        (cd "$work_dir" && find . -type f -not -path './.git/*' | head -20)
        if [ "$file_count" -gt 20 ]; then
            echo "  ... plus $((file_count - 20)) more where that came from"
        fi

        # Initialize state file with current source HEAD
        local state_path
        state_path=$(get_state_path "$source_dir")
        git -C "$source_dir" rev-parse HEAD > "$state_path"
    fi
}
