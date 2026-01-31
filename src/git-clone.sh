# ============================================================================
# Git clone with sparse checkout
# ============================================================================

# Get current branch from source project
get_source_branch() {
    local source_dir="$1"
    git -C "$source_dir" branch --show-current
}

# Create the intermediary git clone with sparse checkout
# Arguments: $1 = source directory (defaults to pwd)
create_intermediary_clone() {
    local source_dir="${1:-$(pwd)}"
    local caged_dir="$source_dir/.caged"
    local intermediary_dir="$caged_dir/intermediary"
    local work_dir="$caged_dir/work"

    # Capture source branch before we start
    local source_branch
    source_branch=$(get_source_branch "$source_dir")
    echo "Source branch: $source_branch"

    echo ""
    echo "Creating intermediary clone..."

    # Clean up existing .caged directory if it exists
    if [ -d "$caged_dir" ]; then
        echo "  Removing existing .caged directory..."
        run rm -rf "$caged_dir"
    fi

    run mkdir -p "$caged_dir"

    # Enable filter support in the source repo
    echo "  Enabling uploadpack.allowFilter..."
    run git -C "$source_dir" config uploadpack.allowFilter true

    # Create shallow sparse clone
    echo "  Creating shallow sparse clone..."
    run git clone --depth 1 --sparse --filter=blob:none "file://$source_dir" "$intermediary_dir"

    # Initialize sparse-checkout in no-cone mode (allows gitignore-style patterns)
    echo "  Initializing sparse-checkout (no-cone mode)..."
    run git -C "$intermediary_dir" sparse-checkout init --no-cone

    # Build sparse-checkout patterns: start with /* to include all, then add excludes
    local sparse_patterns=("/*")

    # Add exclude patterns from config (already in gitignore format)
    if [ -n "$cfg_exclude" ]; then
        IFS='|' read -ra excludes <<< "$cfg_exclude"
        for pattern in "${excludes[@]}"; do
            if [[ "$pattern" != "!"* ]]; then
                sparse_patterns+=("!$pattern")
            else
                sparse_patterns+=("$pattern")
            fi
        done
    fi

    # Apply sparse-checkout patterns
    echo "  Setting sparse-checkout patterns..."
    echo "    Include: /*"
    if [ -n "$cfg_exclude" ]; then
        IFS='|' read -ra excludes <<< "$cfg_exclude"
        for pattern in "${excludes[@]}"; do
            if [[ "$pattern" != "!"* ]]; then
                echo "    Exclude: !$pattern"
            else
                echo "    Pattern: $pattern"
            fi
        done
    fi
    run git -C "$intermediary_dir" sparse-checkout set "${sparse_patterns[@]}"

    echo ""
    echo "Intermediary clone created at: $intermediary_dir"

    # Create work directory from intermediary
    echo ""
    echo "Creating work directory..."
    run git clone "$intermediary_dir" "$work_dir"

    # Create claude branch for work
    echo "  Creating branch: claude/$source_branch"
    run git -C "$work_dir" checkout -b "claude/$source_branch"

    echo ""
    echo "Work directory created at: $work_dir"
    echo "  Branch: claude/$source_branch"

    # Show what files are in work (skip in dry-run)
    if [ "$dry_run" != true ]; then
        echo ""
        echo "Files in work directory:"
        local file_count
        file_count=$(cd "$work_dir" && find . -type f -not -path './.git/*' | wc -l)
        (cd "$work_dir" && find . -type f -not -path './.git/*' | head -20)
        if [ "$file_count" -gt 20 ]; then
            echo "  ... and $((file_count - 20)) more files"
        fi
    fi
}
