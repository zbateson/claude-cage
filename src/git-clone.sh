# ============================================================================
# Git clone with sparse checkout
# ============================================================================

# Build sparse-checkout patterns from config excludes
# Sets: sparse_checkout_excludes (array)
build_sparse_checkout_excludes() {
    sparse_checkout_excludes=()

    # exclude.path -> !/path/to/file
    if [ -n "$cfg_exclude_path" ]; then
        IFS='|' read -ra paths <<< "$cfg_exclude_path"
        for path in "${paths[@]}"; do
            sparse_checkout_excludes+=("!/$path")
        done
    fi

    # exclude.name -> !**/name (matches anywhere in tree)
    if [ -n "$cfg_exclude_name" ]; then
        IFS='|' read -ra names <<< "$cfg_exclude_name"
        for name in "${names[@]}"; do
            # If name contains wildcards, use as-is with !
            # Otherwise wrap with **/ to match anywhere
            if [[ "$name" == *"*"* ]]; then
                sparse_checkout_excludes+=("!$name")
            else
                sparse_checkout_excludes+=("!**/$name")
            fi
        done
    fi

    # exclude.belowPath -> !/path and !/path/**
    if [ -n "$cfg_exclude_belowPath" ]; then
        IFS='|' read -ra belowPaths <<< "$cfg_exclude_belowPath"
        for path in "${belowPaths[@]}"; do
            sparse_checkout_excludes+=("!/$path")
            sparse_checkout_excludes+=("!/$path/**")
        done
    fi

    # exclude.regex -> not supported, warn if present
    if [ -n "$cfg_exclude_regex" ]; then
        echo "WARNING: exclude.regex patterns are not supported in git sparse-checkout mode."
        echo "         The following patterns will be ignored:"
        IFS='|' read -ra regexes <<< "$cfg_exclude_regex"
        for regex in "${regexes[@]}"; do
            echo "           - $regex"
        done
    fi
}

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

    # Create .caged directory
    mkdir -p "$caged_dir"

    # Enable filter support in the source repo
    echo "  Enabling uploadpack.allowFilter..."
    git -C "$source_dir" config uploadpack.allowFilter true

    # Create shallow sparse clone
    echo "  Creating shallow sparse clone..."
    git clone --depth 1 --sparse --filter=blob:none "file://$source_dir" "$intermediary_dir"

    # Initialize sparse-checkout in no-cone mode (allows exclude patterns)
    echo "  Initializing sparse-checkout (no-cone mode)..."
    git -C "$intermediary_dir" sparse-checkout init --no-cone

    # Build exclude patterns from config
    build_sparse_checkout_excludes

    # Build the sparse-checkout set command
    # Start with '/*' to include everything, then add excludes
    local sparse_patterns=("/*")
    for exclude in "${sparse_checkout_excludes[@]}"; do
        sparse_patterns+=("$exclude")
    done

    # Apply sparse-checkout patterns
    if [ ${#sparse_patterns[@]} -gt 0 ]; then
        echo "  Setting sparse-checkout patterns..."
        echo "    Include: /*"
        for exclude in "${sparse_checkout_excludes[@]}"; do
            echo "    Exclude: $exclude"
        done
        git -C "$intermediary_dir" sparse-checkout set "${sparse_patterns[@]}"
    fi

    echo ""
    echo "Intermediary clone created at: $intermediary_dir"

    # Show what files are checked out
    echo ""
    echo "Files in sparse checkout:"
    (cd "$intermediary_dir" && find . -type f -not -path './.git/*' | head -20)
    local file_count=$(cd "$intermediary_dir" && find . -type f -not -path './.git/*' | wc -l)
    if [ "$file_count" -gt 20 ]; then
        echo "  ... and $((file_count - 20)) more files"
    fi
}
