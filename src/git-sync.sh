# ============================================================================
# Git sync operations (fetch/merge from intermediary)
# ============================================================================

# Check if existing cage is in sync with source
# Returns: "no_cage" | "in_sync" | "ahead_clean" | "ahead_dirty"
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - work_dir: The cage work directory
#   $3 - state_path: Path to the state file
check_cage_state() {
    local source_dir="$1"
    local work_dir="$2"
    local state_path="$3"

    # No existing cage
    if [ ! -d "$work_dir" ] || [ ! -f "$state_path" ]; then
        echo "no_cage"
        return
    fi

    # Get current source HEAD and last synced state
    local source_head last_state
    source_head=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)
    last_state=$(cat "$state_path" 2>/dev/null)

    # In sync - source hasn't moved
    if [ "$source_head" = "$last_state" ]; then
        echo "in_sync"
        return
    fi

    # Source is ahead - check if work dir is clean
    local work_status
    work_status=$(git -C "$work_dir" status --porcelain 2>/dev/null)

    if [ -z "$work_status" ]; then
        echo "ahead_clean"
    else
        echo "ahead_dirty"
    fi
}

# Show diff of uncommitted changes in work directory
# Arguments:
#   $1 - work_dir: The cage work directory
show_cage_diff() {
    local work_dir="$1"
    echo ""
    echo "Changes in the cage:"
    echo "--------------------"
    git -C "$work_dir" diff 2>/dev/null
    git -C "$work_dir" diff --cached 2>/dev/null
    # Show untracked files
    local untracked
    untracked=$(git -C "$work_dir" ls-files --others --exclude-standard 2>/dev/null)
    if [ -n "$untracked" ]; then
        echo ""
        echo "Untracked files:"
        echo "$untracked" | sed 's/^/  /'
    fi
    echo "--------------------"
    echo ""
}

# Apply source commits on top of current cage state
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - intermediary_dir: The intermediary directory
#   $3 - state_path: Path to the state file
#   $4 - exclude_patterns: Pipe-delimited exclude patterns
apply_source_commits_to_cage() {
    local source_dir="$1"
    local intermediary_dir="$2"
    local state_path="$3"
    local exclude_patterns="$4"

    local last_state source_head
    last_state=$(cat "$state_path" 2>/dev/null)
    source_head=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)

    echo "Bringin' the cage up to speed..."
    echo "  From: ${last_state:0:8}"
    echo "  To:   ${source_head:0:8}"

    # Build pathspec excludes
    local pathspec_excludes=""
    if [ -n "$exclude_patterns" ]; then
        IFS='|' read -ra patterns <<< "$exclude_patterns"
        for pattern in "${patterns[@]}"; do
            pathspec_excludes="$pathspec_excludes :(exclude,glob)$pattern"
        done
    fi

    # Get commits between last state and current HEAD
    local commits
    commits=$(git -C "$source_dir" rev-list --reverse "$last_state..$source_head" 2>/dev/null)

    if [ -z "$commits" ]; then
        echo "  No commits to apply."
        return 0
    fi

    local commit_count=0
    local failed=false

    for commit in $commits; do
        commit_count=$((commit_count + 1))
        local subject
        subject=$(git -C "$source_dir" log -1 --format=%s "$commit")
        echo "  [$commit_count] ${subject:0:50}"

        # Generate patch excluding sensitive files
        local patch
        if [ -n "$pathspec_excludes" ]; then
            patch=$(git -C "$source_dir" format-patch -1 "$commit" --stdout -- $pathspec_excludes 2>/dev/null)
        else
            patch=$(git -C "$source_dir" format-patch -1 "$commit" --stdout 2>/dev/null)
        fi

        # Check if patch has changes
        if echo "$patch" | grep -q "^diff --git"; then
            if ! (cd "$intermediary_dir" && echo "$patch" | git am --3way 2>/dev/null); then
                echo "  Failed to apply. You may need to resolve this manually."
                git -C "$intermediary_dir" am --abort 2>/dev/null || true
                failed=true
                break
            fi
        fi
    done

    if [ "$failed" = false ]; then
        # Update state file
        echo "$source_head" > "$state_path"
        echo "  All caught up."
    fi
}

# Handle dirty cage with user prompts
# Sets global DIRTY_CAGE_RESULT to: "continue" | "recreate" | "exit"
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - work_dir: The cage work directory
#   $3 - intermediary_dir: The intermediary directory
#   $4 - state_path: Path to the state file
#   $5 - exclude_patterns: Pipe-delimited exclude patterns
DIRTY_CAGE_RESULT=""
handle_dirty_cage() {
    local source_dir="$1"
    local work_dir="$2"
    local intermediary_dir="$3"
    local state_path="$4"
    local exclude_patterns="$5"

    local last_state source_head
    last_state=$(cat "$state_path" 2>/dev/null)
    source_head=$(git -C "$source_dir" rev-parse HEAD 2>/dev/null)

    echo ""
    echo "Hold up. Your source repo's moved ahead, but there's uncommitted work in the cage."
    echo ""
    echo "  Source HEAD:  ${source_head:0:8}"
    echo "  Cage synced:  ${last_state:0:8}"
    echo ""
    echo "Uncommitted changes in cage:"
    git -C "$work_dir" status --short 2>/dev/null | head -10 | sed 's/^/  /'
    local change_count
    change_count=$(git -C "$work_dir" status --short 2>/dev/null | wc -l)
    if [ "$change_count" -gt 10 ]; then
        echo "  ... and $((change_count - 10)) more"
    fi

    local read_failed=0
    while true; do
        echo ""
        echo "What do you wanna do?"
        echo "  1) Apply source commits on top (keep cage changes)"
        echo "  2) Go in as-is (ignore the mismatch)"
        echo "  3) Clear it all and start fresh"
        echo "  4) Show diff of cage changes"
        echo "  q) Quit"
        echo ""
        printf "Choice [1-4/q]: "

        # Try /dev/tty first, fall back to stdin
        local choice=""
        if [ -e /dev/tty ]; then
            read -r choice </dev/tty || read_failed=1
        else
            read -r choice || read_failed=1
        fi

        # If read failed or returned empty twice, we're non-interactive
        if [ "$read_failed" = 1 ] || [ -z "$choice" ]; then
            echo ""
            echo "Can't get input (non-interactive). Goin' in as-is."
            DIRTY_CAGE_RESULT="continue"
            return
        fi

        case "$choice" in
            1)
                apply_source_commits_to_cage "$source_dir" "$intermediary_dir" "$state_path" "$exclude_patterns"
                DIRTY_CAGE_RESULT="continue"
                return
                ;;
            2)
                echo "Alright, goin' in as-is. You're flyin' blind on those new commits."
                DIRTY_CAGE_RESULT="continue"
                return
                ;;
            3)
                echo "Wipin' the slate clean..."
                DIRTY_CAGE_RESULT="recreate"
                return
                ;;
            4)
                show_cage_diff "$work_dir"
                ;;
            q|Q)
                DIRTY_CAGE_RESULT="exit"
                return
                ;;
            *)
                echo "Pick a number, friend. 1, 2, 3, 4, or q."
                ;;
        esac
    done
}

# Save a failed patch for later recovery
# Arguments:
#   $1 - source_dir: The source directory (where user will see the patch)
#   $2 - patch content
#   $3 - branch name
#   $4 - commit subject (for filename)
save_failed_patch() {
    local source_dir="${1%/}"  # Strip trailing slash if present
    local patch="$2"
    local branch="$3"
    local subject="$4"

    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local failed_dir="$source_dir/claude-cage-failed-patches/$sanitized_branch"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local safe_subject
    safe_subject=$(echo "$subject" | sed 's/[^a-zA-Z0-9_-]/_/g' | cut -c1-50)

    mkdir -p "$failed_dir"
    local patch_file="$failed_dir/${timestamp}_${safe_subject}.patch"
    echo "$patch" > "$patch_file"
    echo "  Saved patch to: $patch_file"
    echo "  (Shows up in git status - apply with: git apply $patch_file)"
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
            save_failed_patch "$source_dir" "$patch" "$target_branch" "$commit_msg"
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
                save_failed_patch "$source_dir" "$patch" "$target_branch" "$commit_msg"
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

    # Need to set branch for get_cage_path
    CLAUDE_CAGE_BRANCH=$(get_source_branch "$source_dir")
    export CLAUDE_CAGE_BRANCH

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
