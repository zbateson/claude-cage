# ============================================================================
# Git clone with sparse checkout
# ============================================================================

# Create the intermediary git clone with sparse checkout
# Arguments: $1 = source directory (defaults to pwd)
create_intermediary_clone() {
    local source_dir="${1:-$(pwd)}"
    local caged_dir="$source_dir/.caged"
    local intermediary_dir="$caged_dir/intermediary"

    echo "Creating intermediary clone..."

    # Clean up existing .caged directory if it exists
    if [ -d "$caged_dir" ]; then
        echo "  Removing existing .caged directory..."
        rm -rf "$caged_dir"
    fi

    mkdir -p "$caged_dir"

    # Enable filter support in the source repo
    echo "  Enabling uploadpack.allowFilter..."
    git -C "$source_dir" config uploadpack.allowFilter true

    # Create shallow sparse clone
    echo "  Creating shallow sparse clone..."
    git clone --depth 1 --sparse --filter=blob:none "file://$source_dir" "$intermediary_dir"

    # Initialize sparse-checkout in no-cone mode (allows gitignore-style patterns)
    echo "  Initializing sparse-checkout (no-cone mode)..."
    git -C "$intermediary_dir" sparse-checkout init --no-cone

    # Build sparse-checkout patterns: start with /* to include all, then add excludes
    local sparse_patterns=("/*")

    # Add exclude patterns from config (already in gitignore format)
    if [ -n "$cfg_exclude" ]; then
        IFS='|' read -ra excludes <<< "$cfg_exclude"
        for pattern in "${excludes[@]}"; do
            # Patterns should already have ! prefix if they're excludes
            # If not, add it
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
    git -C "$intermediary_dir" sparse-checkout set "${sparse_patterns[@]}"

    echo ""
    echo "Intermediary clone created at: $intermediary_dir"

    # Show what files are checked out
    echo ""
    echo "Files in sparse checkout:"
    local file_count
    file_count=$(cd "$intermediary_dir" && find . -type f -not -path './.git/*' | wc -l)
    (cd "$intermediary_dir" && find . -type f -not -path './.git/*' | head -20)
    if [ "$file_count" -gt 20 ]; then
        echo "  ... and $((file_count - 20)) more files"
    fi
}
