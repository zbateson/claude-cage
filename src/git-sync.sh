# ============================================================================
# Git sync operations (fetch/merge from intermediary)
# ============================================================================

# Apply changes from intermediary to source using format-patch/git-am
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - refname: The git ref that was pushed (e.g., refs/heads/claude/main)
sync_to_source() {
    local source_dir="$1"
    local refname="$2"
    local intermediary_dir="$source_dir/.caged/intermediary"

    # Skip the initial commit (it's just a copy of source files)
    local commit_msg
    commit_msg=$(git -C "$intermediary_dir" log -1 --format=%s "$refname")
    if [ "$commit_msg" = "Initial commit from claude-cage" ]; then
        echo "Skipping initial commit sync"
        return 0
    fi

    echo "Syncing from intermediary to source: $refname"

    # Apply the latest commit from intermediary using format-patch/git-am
    if git -C "$intermediary_dir" format-patch -1 "$refname" --stdout | git -C "$source_dir" am --3way; then
        echo "  Applied commit to source"
    else
        echo "  Warning: Failed to apply commit (may need manual merge)"
        git -C "$source_dir" am --abort 2>/dev/null || true
    fi
}

# Start the pipe listener in background
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - caged_dir: The .caged directory
# Sets: PIPE_LISTENER_PID
start_pipe_listener() {
    local source_dir="$1"
    local caged_dir="$2"
    local pipe_path="$caged_dir/.pipe"

    # Run listener in background
    # Open pipe read-write to avoid blocking (there may be no writer yet)
    (
        exec 3<>"$pipe_path"
        while read -r refname newrev <&3; do
            if [ -n "$refname" ]; then
                sync_to_source "$source_dir" "$refname"
            fi
        done
    ) &
    PIPE_LISTENER_PID=$!
}

# Stop the pipe listener
# Arguments:
#   $1 - listener_pid: PID of the listener process
stop_pipe_listener() {
    local listener_pid="$1"
    if [ -n "$listener_pid" ] && kill -0 "$listener_pid" 2>/dev/null; then
        kill "$listener_pid" 2>/dev/null
        wait "$listener_pid" 2>/dev/null
    fi
}

# Manual git merge from intermediary (for --git-merge option)
# Arguments:
#   $1 - source_dir: The original source directory
manual_git_merge() {
    local source_dir="$1"
    local intermediary_dir="$source_dir/.caged/intermediary"

    if [ ! -d "$intermediary_dir" ]; then
        echo "No intermediary directory found at $intermediary_dir"
        echo "Run claude-cage first to create the cage."
        exit 1
    fi

    # Add intermediary as a remote if not already
    if ! git -C "$source_dir" remote | grep -q "^intermediary$"; then
        run git -C "$source_dir" remote add intermediary "$intermediary_dir"
    fi

    echo "Fetching all refs from intermediary..."
    run git -C "$source_dir" fetch intermediary

    echo ""
    echo "Available refs from intermediary:"
    git -C "$source_dir" branch -r 2>/dev/null | grep -E "^\\s*intermediary/" | sed 's/^/  /' || echo "  (none yet)"

    echo ""
    echo "To merge a specific ref, run:"
    echo "  git merge intermediary/<branch>"
}
