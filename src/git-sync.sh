# ============================================================================
# Git sync operations (fetch/merge from intermediary)
# ============================================================================

# Sanitize branch name for use in file paths (replace / with --)
sanitize_branch_name() {
    echo "$1" | sed 's|/|--|g'
}

# Save a failed patch for later recovery
# Arguments:
#   $1 - patch content
#   $2 - branch name
#   $3 - commit subject (for filename)
save_failed_patch() {
    local patch="$1"
    local branch="$2"
    local subject="$3"

    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local failed_dir="$CLAUDE_CAGE_CACHE/failed-patches/$sanitized_branch"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local safe_subject
    safe_subject=$(echo "$subject" | sed 's/[^a-zA-Z0-9_-]/_/g' | cut -c1-50)

    mkdir -p "$failed_dir"
    local patch_file="$failed_dir/${timestamp}_${safe_subject}.patch"
    echo "$patch" > "$patch_file"
    echo "  Saved patch to: $patch_file"
}

# Apply changes from intermediary to source using format-patch/git-am
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - intermediary_dir: The intermediary directory
#   $3 - refname: The git ref that was pushed (e.g., refs/heads/claude/main)
#   $4 - target_branch: The branch to apply commits to (branch when cage started)
sync_to_source() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local refname="$3"
    local target_branch="$4"

    # Skip the initial commit (it's just a copy of source files)
    local commit_msg
    commit_msg=$(git -C "$intermediary_dir" log -1 --format=%s "$refname")
    if [ "$commit_msg" = "Initial commit from claude-cage" ]; then
        echo "First commit, nothin' to sync yet"
        return 0
    fi

    echo "Bringin' changes home: $refname -> $target_branch"

    # Get the patch
    local patch
    patch=$(git -C "$intermediary_dir" format-patch -1 "$refname" --stdout)

    # Check if user is still on the target branch
    local current_branch
    current_branch=$(git -C "$source_dir" branch --show-current)

    if [ "$current_branch" = "$target_branch" ]; then
        # Simple case - user still on same branch, use git am
        if echo "$patch" | git -C "$source_dir" am --3way; then
            echo "  Got it. Changes are in."
        else
            echo "  Well now, that didn't go smooth. Might need to merge this one yourself."
            git -C "$source_dir" am --abort 2>/dev/null || true
            save_failed_patch "$patch" "$target_branch" "$commit_msg"
        fi
    else
        # User switched branches - apply to target branch via temp index
        echo "  You switched branches, applyin' to $target_branch without disturbin' your work..."

        local tmp_index="$source_dir/.git/claude-cage-tmp-index"

        # Get commit metadata from the patch
        local author_name author_email author_date
        author_name=$(echo "$patch" | grep "^From:" | head -1 | sed 's/^From: //' | sed 's/ <.*//')
        author_email=$(echo "$patch" | grep "^From:" | head -1 | sed 's/.*<\(.*\)>/\1/')
        author_date=$(echo "$patch" | grep "^Date:" | head -1 | sed 's/^Date: //')

        (
            export GIT_INDEX_FILE="$tmp_index"
            cd "$source_dir"

            # Load target branch tree into temp index
            git read-tree "$target_branch"

            # Apply patch to temp index
            if echo "$patch" | git apply --cached; then
                # Write new tree
                local tree
                tree=$(git write-tree)

                # Create commit with preserved metadata via environment variables
                local parent
                parent=$(git rev-parse "$target_branch")

                # Set author info from patch
                export GIT_AUTHOR_NAME="$author_name"
                export GIT_AUTHOR_EMAIL="$author_email"
                [ -n "$author_date" ] && export GIT_AUTHOR_DATE="$author_date"

                local new_commit
                new_commit=$(git commit-tree "$tree" -p "$parent" -m "$commit_msg")

                # Update the branch ref
                git update-ref "refs/heads/$target_branch" "$new_commit"

                echo "  Got it. Changes are on $target_branch."
            else
                echo "  Patch didn't apply clean to $target_branch."
                save_failed_patch "$patch" "$target_branch" "$commit_msg"
            fi
        )

        # Clean up temp index
        rm -f "$tmp_index"
    fi
}

# Start the pipe listener in background
# Arguments:
#   $1 - source_dir: The original source directory
#   $2 - intermediary_dir: The intermediary directory
#   $3 - pipe_path: The pipe file path
#   $4 - target_branch: The branch to apply commits to
# Sets: PIPE_LISTENER_PID
start_pipe_listener() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local pipe_path="$3"
    local target_branch="$4"

    # Run listener in background
    # Open pipe read-write to avoid blocking (there may be no writer yet)
    # Note: Variables are captured at fork time, including target_branch
    (
        exec 3<>"$pipe_path"
        while read -r refname newrev <&3; do
            if [ -n "$refname" ]; then
                if [ -z "$target_branch" ]; then
                    echo "claude-cage: No target branch - can't sync. Was source repo on a branch when cage started?"
                else
                    sync_to_source "$source_dir" "$intermediary_dir" "$refname" "$target_branch"
                fi
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
    local intermediary_dir
    intermediary_dir=$(get_cage_path "$source_dir" "intermediary")

    if [ ! -d "$intermediary_dir" ]; then
        echo "Ain't no cage here at $intermediary_dir"
        echo "You gotta run claude-cage first, friend."
        exit 1
    fi

    # Add intermediary as a remote if not already
    if ! git -C "$source_dir" remote | grep -q "^intermediary$"; then
        run git -C "$source_dir" remote add intermediary "$intermediary_dir"
    fi

    echo "Grabbin' what Claude's been workin' on..."
    run git -C "$source_dir" fetch intermediary

    echo ""
    echo "Here's what's waitin' for ya:"
    git -C "$source_dir" branch -r 2>/dev/null | grep -E "^\\s*intermediary/" | sed 's/^/  /' || echo "  (none yet)"

    echo ""
    echo "When you're ready, just run:"
    echo "  git merge intermediary/<branch>"
}
