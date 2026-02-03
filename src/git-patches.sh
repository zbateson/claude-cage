# ============================================================================
# Failed patch handling (recovery from sync failures)
# ============================================================================

# List all branches that have pending patches for a given direction
# Arguments:
#   $1 - source_dir: The source project directory
#   $2 - direction: "from-intermediary" or "to-intermediary"
# Returns: Space-separated list of branch names (unsanitized)
list_pending_patch_branches() {
    local source_dir="$1"
    local direction="$2"
    local failed_root="$source_dir/claude-cage-failed-patches/$direction"

    if [ ! -d "$failed_root" ]; then
        return
    fi

    local branches=""
    for dir in "$failed_root"/*/; do
        [ -d "$dir" ] || continue
        local patch_count
        patch_count=$(find "$dir" -maxdepth 1 -name "*.patch" -type f 2>/dev/null | wc -l)
        if [ "$patch_count" -gt 0 ]; then
            local sanitized_name
            sanitized_name=$(basename "$dir")
            # Unsanitize: -- back to /
            local branch_name
            branch_name=$(echo "$sanitized_name" | sed 's/--/\//g')
            branches="$branches $branch_name"
        fi
    done

    echo "$branches" | xargs  # trim whitespace
}

# Count patches for a specific branch and direction
# Arguments:
#   $1 - source_dir
#   $2 - direction: "from-intermediary" or "to-intermediary"
#   $3 - branch name
count_patches_for_branch() {
    local source_dir="$1"
    local direction="$2"
    local branch="$3"
    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local failed_dir="$source_dir/claude-cage-failed-patches/$direction/$sanitized_branch"

    if [ ! -d "$failed_dir" ]; then
        echo "0"
        return
    fi

    find "$failed_dir" -maxdepth 1 -name "*.patch" -type f 2>/dev/null | wc -l
}

# Save a failed patch for later recovery
# Arguments:
#   $1 - source_dir: The source directory (where user will see the patch)
#   $2 - direction: "from-intermediary" or "to-intermediary"
#   $3 - patch content
#   $4 - branch name
#   $5 - commit subject (for filename)
#   $6 - work_dir (optional): Also save to work directory for Claude to see
save_failed_patch() {
    local source_dir="${1%/}"  # Strip trailing slash if present
    local direction="$2"
    local patch="$3"
    local branch="$4"
    local subject="$5"
    local work_dir="${6%/}"  # Optional

    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$branch")
    local rel_path="claude-cage-failed-patches/$direction/$sanitized_branch"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local safe_subject
    safe_subject=$(echo "$subject" | sed 's/[^a-zA-Z0-9_-]/_/g' | cut -c1-50)
    local patch_filename="${timestamp}_${safe_subject}.patch"

    # Save to source directory
    local source_failed_dir="$source_dir/$rel_path"
    mkdir -p "$source_failed_dir"
    local patch_file="$source_failed_dir/$patch_filename"
    echo "$patch" > "$patch_file"
    echo "  Saved patch to: $patch_file"

    # Also save to work directory if provided (so Claude can see it inside cage)
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        local work_failed_dir="$work_dir/$rel_path"
        mkdir -p "$work_failed_dir"
        echo "$patch" > "$work_failed_dir/$patch_filename"
        echo "  Also available inside cage at: $rel_path/$patch_filename"
    fi

    echo "  (Apply with: git am <patch_file>)"
}

# Apply a single patch with conflict handling
# Arguments:
#   $1 - source_dir
#   $2 - patch_file
# Returns: "applied" | "skipped" | "abort" | "quit"
# Sets: PATCH_RESULT
PATCH_RESULT=""
apply_single_patch() {
    local source_dir="$1"
    local patch_file="$2"
    local patch_name
    patch_name=$(basename "$patch_file")

    echo ""
    echo "Applyin': $patch_name"

    if git -C "$source_dir" am --3way "$patch_file" 2>/dev/null; then
        echo "  ${GREEN}Applied clean.${NC}"
        rm -f "$patch_file"
        PATCH_RESULT="applied"
        return
    fi

    # Conflict - show what happened
    echo ""
    echo "${YELLOW}Hit a snag.${NC} This patch has conflicts."
    echo ""
    echo "Here's the patch that failed:"
    echo "-----------------------------"
    git -C "$source_dir" am --show-current-patch=diff 2>/dev/null | head -50
    echo "-----------------------------"
    echo ""

    while true; do
        echo "What do you wanna do?"
        echo "  1) Open a shell to fix it manually (then 'git am --continue')"
        echo "  2) Skip this patch (keeps file for later)"
        echo "  3) Abort and go back to main menu"
        echo "  q) Quit claude-cage"
        echo ""
        printf "Choice [1-3/q]: "

        local choice=""
        if [ -e /dev/tty ]; then
            read -r choice </dev/tty
        else
            read -r choice
        fi

        case "$choice" in
            1)
                echo ""
                echo "Droppin' you into a shell. Fix the conflicts, then:"
                echo "  git add <fixed-files>"
                echo "  git am --continue"
                echo ""
                echo "Or if you can't fix it:"
                echo "  git am --abort"
                echo "  exit"
                echo ""
                (cd "$source_dir" && ${SHELL:-/bin/bash})

                # Check if they resolved it
                if ! git -C "$source_dir" am --show-current-patch >/dev/null 2>&1; then
                    # No longer in am state - they either continued or aborted
                    if git -C "$source_dir" log -1 --format=%s 2>/dev/null | grep -q "$(head -1 "$patch_file" 2>/dev/null | sed 's/^From [^ ]* //' | cut -c1-20)"; then
                        echo "  ${GREEN}Looks like you got it.${NC}"
                        rm -f "$patch_file"
                        PATCH_RESULT="applied"
                    else
                        echo "  Patch was aborted. Keepin' the file for later."
                        PATCH_RESULT="skipped"
                    fi
                    return
                fi
                # Still in am state, loop back
                echo "Still got conflicts. Let's try again."
                ;;
            2)
                git -C "$source_dir" am --abort 2>/dev/null || true
                echo "  Skippin' this one. Patch file stays for later."
                PATCH_RESULT="skipped"
                return
                ;;
            3)
                git -C "$source_dir" am --abort 2>/dev/null || true
                PATCH_RESULT="abort"
                return
                ;;
            q|Q)
                git -C "$source_dir" am --abort 2>/dev/null || true
                PATCH_RESULT="quit"
                return
                ;;
            *)
                echo "Pick a number, friend."
                ;;
        esac
    done
}

# Apply all patches for a branch
# Arguments:
#   $1 - source_dir
#   $2 - direction: "from-intermediary" or "to-intermediary"
#   $3 - branch name
#   $4 - original branch (to switch back to)
# Returns: "done" | "abort" | "quit"
# Sets: BRANCH_PATCHES_RESULT
BRANCH_PATCHES_RESULT=""
apply_patches_for_branch() {
    local source_dir="$1"
    local direction="$2"
    local target_branch="$3"
    local original_branch="$4"

    local sanitized_branch
    sanitized_branch=$(sanitize_branch_name "$target_branch")
    local failed_dir="$source_dir/claude-cage-failed-patches/$direction/$sanitized_branch"

    local current_branch
    current_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null)

    # Switch if needed
    if [ "$current_branch" != "$target_branch" ]; then
        echo ""
        echo "Switchin' from '$current_branch' to '$target_branch' to apply patches..."
        if ! git -C "$source_dir" checkout "$target_branch" 2>/dev/null; then
            echo "${RED}Can't switch to $target_branch.${NC} You may need to commit or stash first."
            BRANCH_PATCHES_RESULT="abort"
            return
        fi
    fi

    # Get sorted list of patches (oldest first by filename timestamp)
    local patches
    patches=$(find "$failed_dir" -maxdepth 1 -name "*.patch" -type f 2>/dev/null | sort)

    for patch_file in $patches; do
        [ -f "$patch_file" ] || continue

        apply_single_patch "$source_dir" "$patch_file"

        case "$PATCH_RESULT" in
            "quit")
                # Switch back before quitting
                if [ "$current_branch" != "$target_branch" ] && [ -n "$original_branch" ]; then
                    git -C "$source_dir" checkout "$original_branch" 2>/dev/null || true
                fi
                BRANCH_PATCHES_RESULT="quit"
                return
                ;;
            "abort")
                BRANCH_PATCHES_RESULT="abort"
                return
                ;;
            # applied/skipped - continue to next patch
        esac
    done

    # Check if directory is empty now
    local remaining
    remaining=$(find "$failed_dir" -maxdepth 1 -name "*.patch" -type f 2>/dev/null | wc -l)
    if [ "$remaining" -eq 0 ]; then
        rmdir "$failed_dir" 2>/dev/null || true
        # Clean up parent if empty
        local parent_dir
        parent_dir=$(dirname "$failed_dir")
        rmdir "$parent_dir" 2>/dev/null || true
    fi

    BRANCH_PATCHES_RESULT="done"
}

# Main interactive handler for pending patches
# Arguments:
#   $1 - source_dir: The source project directory
# Returns: "continue" | "quit"
# Sets: PENDING_PATCHES_RESULT
PENDING_PATCHES_RESULT=""
handle_pending_patches() {
    local source_dir="$1"

    local original_branch
    original_branch=$(git -C "$source_dir" branch --show-current 2>/dev/null)

    while true; do
        # Get list of branches with pending patches for each direction
        local from_branches to_branches
        from_branches=$(list_pending_patch_branches "$source_dir" "from-intermediary")
        to_branches=$(list_pending_patch_branches "$source_dir" "to-intermediary")

        if [ -z "$from_branches" ] && [ -z "$to_branches" ]; then
            PENDING_PATCHES_RESULT="continue"
            return
        fi

        # Check if working directory is dirty
        local is_dirty=false
        if [ -n "$(git -C "$source_dir" status --porcelain 2>/dev/null)" ]; then
            is_dirty=true
        fi

        echo ""
        echo "${YELLOW}Hold up.${NC} You've got failed patches waitin' to be applied:"
        echo ""

        if [ -n "$from_branches" ]; then
            echo "  From cage (apply to source):"
            for branch in $from_branches; do
                local count
                count=$(count_patches_for_branch "$source_dir" "from-intermediary" "$branch")
                echo "    $branch: $count patch(es)"
            done
        fi

        if [ -n "$to_branches" ]; then
            echo "  To cage (apply to intermediary):"
            for branch in $to_branches; do
                local count
                count=$(count_patches_for_branch "$source_dir" "to-intermediary" "$branch")
                echo "    $branch: $count patch(es)"
            done
        fi

        echo ""

        if [ "$is_dirty" = true ]; then
            echo "${YELLOW}Note:${NC} Your working directory has uncommitted changes."
            echo "      Commit, stash, or reset them before applyin' patches."
            echo ""
            echo "What do you wanna do?"
            echo "  1) I've cleaned up - check again"
            echo "  2) Delete all pending patches"
            echo "  3) Continue without applyin'"
            echo "  q) Quit"
            echo ""
            printf "Choice [1-3/q]: "
        else
            echo "What do you wanna do?"
            echo "  1) Apply patches one-by-one"
            echo "  2) Delete all pending patches"
            echo "  3) Continue without applyin'"
            echo "  q) Quit"
            echo ""
            printf "Choice [1-3/q]: "
        fi

        local choice=""
        if [ -e /dev/tty ]; then
            read -r choice </dev/tty
        else
            read -r choice
        fi

        case "$choice" in
            1)
                if [ "$is_dirty" = true ]; then
                    # Re-check - loop will re-evaluate
                    echo "Checkin' again..."
                    continue
                fi

                # Apply "from-intermediary" patches (cage -> source)
                for branch in $from_branches; do
                    local count
                    count=$(count_patches_for_branch "$source_dir" "from-intermediary" "$branch")
                    [ "$count" -gt 0 ] || continue

                    echo ""
                    echo "=== From cage -> source, branch: $branch ==="

                    apply_patches_for_branch "$source_dir" "from-intermediary" "$branch" "$original_branch"

                    case "$BRANCH_PATCHES_RESULT" in
                        "quit")
                            PENDING_PATCHES_RESULT="quit"
                            return
                            ;;
                        "abort")
                            # Go back to main menu
                            break 2
                            ;;
                        # done - continue to next branch
                    esac
                done

                # Apply "to-intermediary" patches (source -> cage)
                # Note: These need to be applied to the intermediary, not source
                for branch in $to_branches; do
                    local count
                    count=$(count_patches_for_branch "$source_dir" "to-intermediary" "$branch")
                    [ "$count" -gt 0 ] || continue

                    echo ""
                    echo "=== Source -> cage, branch: $branch ==="
                    echo "${YELLOW}Note:${NC} These patches need to be applied to the cage's intermediary."
                    echo "      Start claude-cage on this branch and apply from there,"
                    echo "      or delete them if no longer needed."

                    # Can't auto-apply these here - they go to intermediary
                    # User needs to handle manually or delete
                done

                # Switch back to original branch if needed
                local current
                current=$(git -C "$source_dir" branch --show-current 2>/dev/null)
                if [ "$current" != "$original_branch" ] && [ -n "$original_branch" ]; then
                    echo ""
                    echo "Switchin' back to '$original_branch'..."
                    git -C "$source_dir" checkout "$original_branch" 2>/dev/null || true
                fi
                # Loop back to check if more patches remain
                ;;
            2)
                echo ""
                echo "Clearin' out all pending patches..."
                rm -rf "$source_dir/claude-cage-failed-patches"
                echo "  Done."
                PENDING_PATCHES_RESULT="continue"
                return
                ;;
            3)
                echo "Alright, movin' on. Those patches'll still be there next time."
                PENDING_PATCHES_RESULT="continue"
                return
                ;;
            q|Q)
                PENDING_PATCHES_RESULT="quit"
                return
                ;;
            *)
                echo "Pick a number, friend."
                ;;
        esac
    done
}
