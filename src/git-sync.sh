# ============================================================================
# Git sync operations (fetch/merge from intermediary)
# ============================================================================

# Fetch and merge changes from intermediary to source
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - refname: The git ref that was pushed (e.g., refs/heads/claude/main)
git_fetch_merge() {
    local source_dir="$1"
    local refname="$2"
    local intermediary_dir="$source_dir/.caged/intermediary"

    echo "Fetching from intermediary: $refname"
    run git -C "$source_dir" fetch "$intermediary_dir" "$refname"
    run git -C "$source_dir" merge FETCH_HEAD --no-edit
}

# Start the pipe listener in background
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - caged_dir: The .caged directory
# Returns: PID of the background listener
start_pipe_listener() {
    local source_dir="$1"
    local caged_dir="$2"
    local pipe_path="$caged_dir/.pipe"

    # Run listener in background
    (
        while read refname newrev < "$pipe_path" 2>/dev/null; do
            if [ -n "$refname" ]; then
                git_fetch_merge "$source_dir" "$refname"
            fi
        done
    ) &
    echo $!
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
        echo "Run claude-cage-git first to create the cage."
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
