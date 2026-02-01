# ============================================================================
# Git archive + fresh init (no history of excluded files)
# ============================================================================

# Base directories for cage data
CLAUDE_CAGE_CACHE="${CLAUDE_CAGE_CACHE:-$HOME/.cache/claude-cage}"
CLAUDE_CAGE_RUNTIME="${CLAUDE_CAGE_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/claude-cage}"

# Get the cache path for a source directory
# Arguments: $1 = source directory, $2 = type (work|intermediary)
get_cage_path() {
    local source_dir="$1"
    local type="$2"
    echo "$CLAUDE_CAGE_CACHE/$type$source_dir"
}

# Get the pipe path for a source directory
get_pipe_path() {
    local source_dir="$1"
    echo "$CLAUDE_CAGE_RUNTIME/pipes$source_dir"
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
    echo "  Setting origin to cage path: /run/claude-cage/intermediary"
    run git -C "$work_dir" remote set-url origin "/run/claude-cage/intermediary"

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
    fi
}
